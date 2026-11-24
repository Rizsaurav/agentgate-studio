import Foundation
import Testing

@testable import AgentGateCore

// Install failure matrix (docs/INSTALL_TEST_MATRIX.md): each case breaks the download on purpose and
// states what must happen. Never a hang, a crash, an unbounded retry, or a bad file kept as a model.

private let payload = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
private let wrongHash = String(repeating: "0", count: 64)

private func tempDir() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent("agentgate-matrix-\(UUID().uuidString)")
}

private func hashOf(_ data: Data) throws -> String {
  let dir = tempDir()
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let file = dir.appendingPathComponent("x")
  try data.write(to: file)
  return try Downloader.sha256(of: file)
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

private func fast() -> Downloader {
  var downloader = Downloader()
  downloader.stallSeconds = 1.5
  return downloader
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct InstallMatrixTests {
  // MARK: Network

  @Test func stalledConnectionIsDetectedAndResumed() async throws {
    let server = try TestHTTPServer(body: payload, fault: .stallFirst(after: 1_000_000))
    defer { server.stop() }
    let destination = tempDir().appendingPathComponent("model.gguf")
    let started = Date()
    try await fast().download(from: server.url(), to: destination, bytes: UInt64(payload.count), sha256: try hashOf(payload)) { _ in }
    #expect(try Data(contentsOf: destination) == payload)
    #expect(server.rangeHeaders.first?.contains("bytes=1000000-") == true)
    #expect(Date().timeIntervalSince(started) < 15)
  }

  @Test func connectionThatKeepsDroppingGivesUpAfterThreeAttempts() async throws {
    let server = try TestHTTPServer(body: payload, fault: .cutAlways(after: 500_000))
    defer { server.stop() }
    let destination = tempDir().appendingPathComponent("model.gguf")
    await #expect {
      try await fast().download(from: server.url(), to: destination, bytes: UInt64(payload.count), sha256: try hashOf(payload)) { _ in }
    } throws: { error in
      if case DownloadError.gaveUp(let attempts, _) = error { attempts == 3 } else { false }
    }
    #expect(server.requestCount == 3)
    #expect(!exists(destination))
  }

  @Test func serverErrorsAreRetriedAtMostThreeTimes() async throws {
    let server = try TestHTTPServer(body: payload, fault: .answer(status: 503))
    defer { server.stop() }
    let destination = tempDir().appendingPathComponent("model.gguf")
    await #expect {
      try await fast().download(from: server.url(), to: destination, bytes: UInt64(payload.count), sha256: wrongHash) { _ in }
    } throws: { error in
      if case DownloadError.gaveUp(let attempts, _) = error { attempts == 3 } else { false }
    }
    #expect(server.requestCount == 3)
  }

  @Test func mirrorThatCannotResumeStillCompletes() async throws {
    let server = try TestHTTPServer(body: payload, fault: .cutFirstThenIgnoreRange(after: 1_000_000))
    defer { server.stop() }
    let destination = tempDir().appendingPathComponent("model.gguf")
    try await fast().download(from: server.url(), to: destination, bytes: UInt64(payload.count), sha256: try hashOf(payload)) { _ in }
    #expect(try Data(contentsOf: destination) == payload)
  }

  // MARK: Wrong or corrupted data

  @Test func wrongContentIsRetriedOnceThenRefusedAndNothingIsKept() async throws {
    let server = try TestHTTPServer(body: payload)
    defer { server.stop() }
    let destination = tempDir().appendingPathComponent("model.gguf")
    await #expect(throws: DownloadError.checksumMismatch) {
      try await fast().download(from: server.url(), to: destination, bytes: UInt64(payload.count), sha256: wrongHash) { _ in }
    }
    #expect(server.requestCount == 2)
    #expect(!exists(destination))
    // A 3 MB file of bad data left in the models folder would be wasted disk, and a trap.
    #expect(!exists(destination.appendingPathExtension("part")))
  }

  @Test func serverSendingMoreThanTheCatalogSaysIsRefused() async throws {
    let server = try TestHTTPServer(body: payload)
    defer { server.stop() }
    let destination = tempDir().appendingPathComponent("model.gguf")
    await #expect {
      try await fast().download(from: server.url(), to: destination, bytes: UInt64(payload.count) - 1000, sha256: wrongHash) { _ in }
    } throws: { error in error is DownloadError }
    #expect(!exists(destination))
    #expect(!exists(destination.appendingPathExtension("part")))
  }

  // MARK: Leftovers from earlier runs

  @Test func partialFileLargerThanExpectedIsReplaced() async throws {
    let server = try TestHTTPServer(body: payload)
    defer { server.stop() }
    let destination = tempDir().appendingPathComponent("model.gguf")
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 7, count: 5_000_000).write(to: destination.appendingPathExtension("part"))
    try await fast().download(from: server.url(), to: destination, bytes: UInt64(payload.count), sha256: try hashOf(payload)) { _ in }
    #expect(try Data(contentsOf: destination) == payload)
  }

  @Test func stalePartialFromADifferentFileIsDiscardedAfterTheChecksumFails() async throws {
    let server = try TestHTTPServer(body: payload)
    defer { server.stop() }
    let destination = tempDir().appendingPathComponent("model.gguf")
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 9, count: 1_000_000).write(to: destination.appendingPathExtension("part"))
    try await fast().download(from: server.url(), to: destination, bytes: UInt64(payload.count), sha256: try hashOf(payload)) { _ in }
    #expect(try Data(contentsOf: destination) == payload)
    #expect(server.requestCount == 2)
  }

  // MARK: The app is quit or two installs collide

  @Test func cancelledDownloadStopsQuicklyKeepsItsProgressAndTheNextRunResumes() async throws {
    let server = try TestHTTPServer(body: payload, fault: .stallFirst(after: 1_000_000))
    defer { server.stop() }
    let destination = tempDir().appendingPathComponent("model.gguf")
    let part = destination.appendingPathExtension("part")
    var slow = Downloader()
    slow.stallSeconds = 60
    let sha = try hashOf(payload)
    let task = Task {
      try await slow.download(from: server.url(), to: destination, bytes: UInt64(payload.count), sha256: sha) { _ in }
    }
    for _ in 0..<100 where (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? UInt64) ?? 0 < 900_000 {
      try await Task.sleep(for: .milliseconds(50))
    }
    let cancelledAt = Date()
    task.cancel()
    await #expect(throws: DownloadError.cancelled) { try await task.value }
    #expect(Date().timeIntervalSince(cancelledAt) < 3)
    #expect(exists(part))
    try await fast().download(from: server.url(), to: destination, bytes: UInt64(payload.count), sha256: sha) { _ in }
    #expect(try Data(contentsOf: destination) == payload)
    #expect(server.rangeHeaders.last?.contains("bytes=") == true)
  }

  @Test func twoInstallsOfTheSameFileCannotRunTogether() async throws {
    let server = try TestHTTPServer(body: payload, fault: .stallFirst(after: 500_000))
    defer { server.stop() }
    let destination = tempDir().appendingPathComponent("model.gguf")
    let sha = try hashOf(payload)
    var slow = Downloader()
    slow.stallSeconds = 60
    let first = Task {
      try await slow.download(from: server.url(), to: destination, bytes: UInt64(payload.count), sha256: sha) { _ in }
    }
    try await Task.sleep(for: .seconds(1))
    await #expect(throws: DownloadError.alreadyInProgress) {
      try await fast().download(from: server.url(), to: destination, bytes: UInt64(payload.count), sha256: sha) { _ in }
    }
    first.cancel()
    _ = try? await first.value
  }

  // MARK: Removing

  @Test func removingAModelCannotEscapeTheModelsFolder() throws {
    let root = tempDir()
    let outside = root.deletingLastPathComponent().appendingPathComponent("agentgate-outside-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let store = ModelStore(root: root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for id in ["../\(outside.lastPathComponent)", "/etc", "a/b", "", ".hidden", String(repeating: "a", count: 65)] {
      #expect(throws: CatalogError.self, "\(id)") { try store.remove(id) }
    }
    #expect(FileManager.default.fileExists(atPath: outside.path))
  }

  // MARK: Disk

  @Test func diskThatFillsUpMidDownloadIsReportedAsDiskFullNotAsNetwork() async throws {
    let image = try SmallDisk(megabytes: 8)
    defer { image.detach() }
    let big = Data(repeating: 5, count: 14_000_000)
    let server = try TestHTTPServer(body: big)
    defer { server.stop() }
    let destination = image.mount.appendingPathComponent("models/model.gguf")
    var downloader = fast()
    downloader.freeSpace = { _ in UInt64.max / 2 }  // the up-front check passes; the disk is still too small
    await #expect(throws: DownloadError.diskFull) {
      try await downloader.download(from: server.url(), to: destination, bytes: UInt64(big.count), sha256: wrongHash) { _ in }
    }
    // The partial file is removed so the user gets the space back.
    #expect(!exists(destination.appendingPathExtension("part")))
  }

  @Test func downloadRefusedBeforeAnyByteWhenDiskIsTooSmall() async throws {
    let server = try TestHTTPServer(body: payload)
    defer { server.stop() }
    let destination = tempDir().appendingPathComponent("model.gguf")
    var downloader = fast()
    downloader.freeSpace = { _ in 1_000 }
    await #expect {
      try await downloader.download(from: server.url(), to: destination, bytes: UInt64(payload.count), sha256: wrongHash) { _ in }
    } throws: { error in
      if case DownloadError.notEnoughDisk = error { true } else { false }
    }
    #expect(server.requestCount == 0)
  }
}

/// A small disk image mounted for one test, so a download can really run out of space.
struct SmallDisk {
  let mount: URL
  private let image: URL

  init(megabytes: Int) throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("agentgate-disk-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    image = base.appendingPathComponent("small.dmg")
    mount = base.appendingPathComponent("mnt")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    try Self.run("/usr/bin/hdiutil", ["create", "-size", "\(megabytes)m", "-fs", "HFS+", "-volname", "agsmall", image.path])
    try Self.run("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-mountpoint", mount.path])
  }

  func detach() {
    try? Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
  }

  private static func run(_ tool: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "SmallDisk", code: Int(process.terminationStatus)) }
  }
}
