import CryptoKit
import Foundation
import Testing

@testable import AgentGateCore

@Suite struct InstallWatcherTests {
  private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
  private let gb: UInt64 = 1_000_000_000

  /// Feeds a download at `rate(second)` bytes per second, one update a second, and returns the first signal.
  private func run(seconds: Int, total: UInt64, rate: (Int) -> Double) -> (WatchSignal, Int)? {
    var watcher = InstallWatcher()
    var bytes: Double = 0
    for second in 0...seconds {
      bytes += rate(second)
      let update = InstallUpdate(step: .download, message: "", completedBytes: UInt64(min(bytes, Double(total))), totalBytes: total)
      if let signal = watcher.observe(update, at: t0.addingTimeInterval(Double(second))) { return (signal, second) }
    }
    return nil
  }

  @Test func aHealthyDownloadSaysNothing() {
    #expect(run(seconds: 300, total: 4 * gb, rate: { _ in 20_000_000 }) == nil)
  }

  @Test func aDownloadThatSlowsDownIsNoticedWithinThirtySeconds() throws {
    let (signal, second) = try #require(run(seconds: 120, total: 4 * gb, rate: { $0 < 20 ? 20_000_000 : 1_000_000 }))
    #expect(signal.kind == .slowDownload)
    #expect(second - 20 <= 30)
    #expect(signal.fact.contains("1.0 MB/s") && signal.fact.contains("20.0 MB/s"))
  }

  @Test func aSlowLineFromTheStartIsNoticedByItsRemainingTime() throws {
    let (signal, second) = try #require(run(seconds: 60, total: 8 * gb, rate: { _ in 500_000 }))
    #expect(signal.kind == .slowDownload && second <= 30)
    #expect(signal.fact.contains("hours"))
  }

  @Test func aStallIsReportedBeforeTheDownloaderGivesUp() throws {
    var watcher = InstallWatcher()
    _ = watcher.observe(InstallUpdate(step: .download, message: "", completedBytes: 100, totalBytes: 1_000), at: t0)
    #expect(watcher.observe(SystemSample(swapUsedBytes: 0, thermal: .nominal, memoryPressure: false), at: t0.addingTimeInterval(10)) == nil)
    let stalled = watcher.observe(SystemSample(swapUsedBytes: 0, thermal: .nominal, memoryPressure: false), at: t0.addingTimeInterval(21))
    let signal = try #require(stalled)
    #expect(signal.kind == .stalled)
  }

  @Test func swapDuringTheLoadIsReportedButNotDuringTheDownload() throws {
    var watcher = InstallWatcher()
    let calm = SystemSample(swapUsedBytes: 1 * gb, thermal: .nominal, memoryPressure: false)
    let swapping = SystemSample(swapUsedBytes: 2 * gb, thermal: .nominal, memoryPressure: false)
    _ = watcher.observe(InstallUpdate(step: .download, message: "", completedBytes: 1, totalBytes: 10), at: t0)
    #expect(watcher.observe(swapping, at: t0.addingTimeInterval(1))?.kind != .memoryPressure)
    _ = watcher.observe(InstallUpdate(step: .load, message: ""), at: t0.addingTimeInterval(2))
    #expect(watcher.observe(calm, at: t0.addingTimeInterval(3)) == nil)
    let swapped = watcher.observe(swapping, at: t0.addingTimeInterval(5))
    let signal = try #require(swapped)
    #expect(signal.kind == .memoryPressure && signal.fact.contains("to disk"))
  }

  @Test func notesAreRateLimitedAndEachKindIsSaidOnce() throws {
    var watcher = InstallWatcher()
    let hot = SystemSample(swapUsedBytes: 0, thermal: .serious, memoryPressure: true)
    _ = watcher.observe(InstallUpdate(step: .load, message: ""), at: t0)
    #expect(watcher.observe(hot, at: t0)?.kind == .thermal)
    // Memory pressure is also true, but a minute has not passed.
    #expect(watcher.observe(hot, at: t0.addingTimeInterval(30)) == nil)
    #expect(watcher.observe(hot, at: t0.addingTimeInterval(61))?.kind == .memoryPressure)
    // Both kinds have been said: nothing more, however long it stays hot.
    #expect(watcher.observe(hot, at: t0.addingTimeInterval(400)) == nil)
  }

  // MARK: Against a real download

  @Test func aThrottledServerProducesANoteWithinThirtySeconds() async throws {
    let body = Data((0..<(40 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    let server = try TestHTTPServer(body: body, fault: .throttleAfter(bytes: 8 << 20, bytesPerSecond: 200_000))
    defer { server.stop() }
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString).gguf")
    defer { try? FileManager.default.removeItem(at: destination.appendingPathExtension("part")) }
    let watch = WatchBox()
    let start = Date()
    let download = Task {
      try await Downloader().download(
        from: server.url(), to: destination, bytes: UInt64(body.count),
        sha256: SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()) { p in
        watch.feed(InstallUpdate(step: .download, message: "", completedBytes: p.completedBytes, totalBytes: p.totalBytes))
      }
    }
    while watch.signal == nil, Date().timeIntervalSince(start) < 40 {
      watch.tick()
      try await Task.sleep(for: .milliseconds(500))
    }
    download.cancel()
    let signal = try #require(watch.signal, "no note within 40 s")
    #expect(signal.kind == .slowDownload)
    #expect(Date().timeIntervalSince(start) <= 30)
  }

  @Test func aFastDownloadProducesNoNote() async throws {
    let body = Data((0..<(16 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
    let server = try TestHTTPServer(body: body)
    defer { server.stop() }
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString).gguf")
    defer { try? FileManager.default.removeItem(at: destination) }
    let watch = WatchBox()
    try await Downloader().download(
      from: server.url(), to: destination, bytes: UInt64(body.count),
      sha256: SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()) { p in
      watch.feed(InstallUpdate(step: .download, message: "", completedBytes: p.completedBytes, totalBytes: p.totalBytes))
    }
    watch.tick()
    #expect(watch.signal == nil)
  }
}

/// The watcher fed from the downloader's thread and a polling loop.
private final class WatchBox: @unchecked Sendable {
  private let lock = NSLock()
  private var watcher = InstallWatcher()
  private var first: WatchSignal?
  var signal: WatchSignal? { lock.withLock { first } }

  func feed(_ update: InstallUpdate) {
    lock.withLock { if first == nil { first = watcher.observe(update, at: Date()) } }
  }

  func tick() {
    lock.withLock {
      if first == nil { first = watcher.observe(SystemSample(swapUsedBytes: 0, thermal: .nominal, memoryPressure: false), at: Date()) }
    }
  }
}
