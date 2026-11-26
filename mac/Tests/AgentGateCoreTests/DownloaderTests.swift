import Foundation
import Testing

@testable import AgentGateCore

private let payload = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })

private func tempFile() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("agentgate-dl-\(UUID().uuidString)/model.gguf")
}

private func digest(_ data: Data) throws -> String {
  let url = tempFile()
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try data.write(to: url)
  return try Downloader.sha256(of: url)
}

@Suite(.serialized) struct DownloaderTests {
  @Test func downloadsAndVerifies() async throws {
    let server = try TestHTTPServer(body: payload)
    defer { server.stop() }
    let destination = tempFile()
    try await Downloader().download(
      from: server.url(), to: destination, bytes: UInt64(payload.count), sha256: try digest(payload)) { _ in }
    #expect(try Data(contentsOf: destination) == payload)
    #expect(!FileManager.default.fileExists(atPath: destination.path + ".part"))
  }

  @Test func resumesAfterDroppedConnection() async throws {
    let server = try TestHTTPServer(body: payload, cutAfter: 1_000_000)
    defer { server.stop() }
    let destination = tempFile()
    let attempts = Attempts()
    try await Downloader().download(
      from: server.url(), to: destination, bytes: UInt64(payload.count), sha256: try digest(payload)
    ) { attempts.record($0.attempt) }
    #expect(try Data(contentsOf: destination) == payload)
    #expect(server.rangeHeaders.count == 1)
    // It resumes from what reached the disk, which can be a little under what the server sent before cutting.
    let start = server.rangeHeaders.first.flatMap { $0.split(separator: "=").last?.split(separator: "-").first }.flatMap { Int($0) }
    #expect((1...1_000_000).contains(start ?? 0))
    #expect(attempts.max == 2)
  }

  @Test func corruptedFileIsNeverKept() async throws {
    let server = try TestHTTPServer(body: payload)
    defer { server.stop() }
    let destination = tempFile()
    await #expect(throws: DownloadError.checksumMismatch) {
      try await Downloader().download(
        from: server.url(), to: destination, bytes: UInt64(payload.count),
        sha256: String(repeating: "0", count: 64)) { _ in }
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  @Test func missingFileIsNotRetried() async throws {
    let server = try TestHTTPServer(body: payload)
    defer { server.stop() }
    await #expect(throws: DownloadError.http(404)) {
      try await Downloader().download(
        from: server.url("/nope"), to: tempFile(), bytes: 10, sha256: String(repeating: "0", count: 64)) { _ in }
    }
  }

  @Test func refusesWhenDiskIsTooSmall() async throws {
    await #expect {
      try await Downloader().download(
        from: URL(string: "http://127.0.0.1:9/x")!, to: tempFile(), bytes: UInt64.max / 2,
        sha256: String(repeating: "0", count: 64)) { _ in }
    } throws: { error in
      if case DownloadError.notEnoughDisk = error { true } else { false }
    }
  }
}

private final class Attempts: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Int] = []
  func record(_ value: Int) { lock.withLock { values.append(value) } }
  var max: Int { lock.withLock { values.max() ?? 0 } }
}
