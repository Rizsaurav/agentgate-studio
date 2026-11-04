import CryptoKit
import Foundation

public enum DownloadError: Error, Equatable, CustomStringConvertible {
  case http(Int)
  case stalled
  case network(String)
  case notEnoughDisk(needed: UInt64, free: UInt64)
  case checksumMismatch
  case sizeMismatch(expected: UInt64, got: UInt64)
  case gaveUp(attempts: Int, last: String)
  case cancelled

  public var description: String {
    switch self {
    case .http(let code): "The server answered with HTTP \(code)."
    case .stalled: "The download stopped receiving data."
    case .network(let reason): "Network error: \(reason)"
    case .notEnoughDisk(let needed, let free):
      "Not enough disk: \(ModelPlanner.gb(needed)) needed, \(ModelPlanner.gb(free)) free."
    case .checksumMismatch: "The downloaded file is corrupted (checksum mismatch)."
    case .sizeMismatch(let expected, let got): "The file is \(got) bytes; \(expected) were expected."
    case .gaveUp(let attempts, let last): "Gave up after \(attempts) attempts. Last error: \(last)"
    case .cancelled: "The download was cancelled."
    }
  }

  var isCorruption: Bool {
    switch self {
    case .checksumMismatch, .sizeMismatch: true
    default: false
    }
  }

  /// Worth resuming: the connection, not the file, was the problem.
  var isTransient: Bool {
    switch self {
    case .stalled, .network: true
    case .http(let code): code >= 500 || code == 429
    default: false
    }
  }
}

public struct DownloadProgress: Sendable, Equatable {
  public var completedBytes: UInt64
  public var totalBytes: UInt64
  public var attempt: Int
}

/// Downloads one file with resume, stall detection, bounded retries and a checksum check.
/// The file appears at its destination only once it is complete and verified.
public struct Downloader: Sendable {
  public var stallSeconds: TimeInterval = 120
  public var maxAttempts = 3
  /// Disk kept free after the download.
  public var diskMargin: UInt64 = ModelPlanner.diskMargin

  public init() {}

  public func download(
    from url: URL, to destination: URL, bytes expected: UInt64, sha256: String,
    progress: @escaping @Sendable (DownloadProgress) -> Void
  ) async throws {
    let fm = FileManager.default
    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let part = destination.appendingPathExtension("part")
    var lastError = ""
    var restartedAfterCorruption = false
    var attempt = 0
    while attempt < maxAttempts {
      attempt += 1
      try Task.checkCancellation()
      let have = (try? fm.attributesOfItem(atPath: part.path)[.size] as? UInt64) ?? 0
      let free = try HardwareProbe.freeDisk(at: destination)
      if expected > have, expected - have + diskMargin > free {
        throw DownloadError.notEnoughDisk(needed: expected - have + diskMargin, free: free)
      }
      do {
        if have < expected {
          try await fetch(url, into: part, from: have, total: expected, attempt: attempt, progress: progress)
        }
        let size = (try fm.attributesOfItem(atPath: part.path)[.size] as? UInt64) ?? 0
        guard size == expected else { throw DownloadError.sizeMismatch(expected: expected, got: size) }
        guard try Self.sha256(of: part) == sha256.lowercased() else { throw DownloadError.checksumMismatch }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: part, to: destination)
        return
      } catch let error as DownloadError where error.isTransient {
        lastError = error.description
      } catch let error as DownloadError where error.isCorruption && !restartedAfterCorruption {
        // A bad partial file cannot be resumed: start once more from zero.
        restartedAfterCorruption = true
        lastError = DownloadError.checksumMismatch.description
        try? fm.removeItem(at: part)
      } catch is CancellationError {
        throw DownloadError.cancelled
      }
    }
    throw DownloadError.gaveUp(attempts: attempt, last: lastError)
  }

  /// Removes any partial file left for `destination`.
  public static func discardPartial(for destination: URL) throws {
    let part = destination.appendingPathExtension("part")
    if FileManager.default.fileExists(atPath: part.path) { try FileManager.default.removeItem(at: part) }
  }

  public static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func fetch(
    _ url: URL, into part: URL, from offset: UInt64, total: UInt64, attempt: Int,
    progress: @escaping @Sendable (DownloadProgress) -> Void
  ) async throws {
    if !FileManager.default.fileExists(atPath: part.path) {
      FileManager.default.createFile(atPath: part.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: part)
    defer { try? handle.close() }
    try handle.seekToEnd()
    var request = URLRequest(url: url)
    if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
    let receiver = Receiver(handle: handle, offset: offset, total: total, attempt: attempt, progress: progress)
    let config = URLSessionConfiguration.ephemeral
    // No bytes for this long ends the request, and the caller resumes it.
    config.timeoutIntervalForRequest = stallSeconds
    let session = URLSession(configuration: config, delegate: receiver, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    try await withTaskCancellationHandler {
      try await receiver.run(session.dataTask(with: request))
    } onCancel: {
      session.invalidateAndCancel()
    }
  }
}

/// Writes response chunks straight to disk and reports progress.
private final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  // Accessed only from the session's serial delegate queue, then read after completion.
  private let handle: FileHandle
  private var completed: UInt64
  private let offset: UInt64
  private let total: UInt64
  private let attempt: Int
  private let progress: @Sendable (DownloadProgress) -> Void
  private var continuation: CheckedContinuation<Void, Error>?
  private var failure: Error?
  private var lastReport = Date.distantPast

  init(handle: FileHandle, offset: UInt64, total: UInt64, attempt: Int,
       progress: @escaping @Sendable (DownloadProgress) -> Void) {
    self.handle = handle
    self.completed = offset
    self.offset = offset
    self.total = total
    self.attempt = attempt
    self.progress = progress
  }

  func run(_ task: URLSessionDataTask) async throws {
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      task.resume()
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                  completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    // A resumed request must answer 206; a 200 would restart the file and corrupt the append.
    let expected = offset > 0 ? 206 : 200
    if code != expected {
      failure = offset > 0 && code == 200 ? DownloadError.network("the server ignored the resume request") : DownloadError.http(code)
      completionHandler(.cancel)
      return
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    do {
      try handle.write(contentsOf: data)
    } catch {
      failure = DownloadError.network("could not write to disk: \(error.localizedDescription)")
      dataTask.cancel()
      return
    }
    completed += UInt64(data.count)
    if Date().timeIntervalSince(lastReport) > 0.25 || completed >= total {
      lastReport = Date()
      progress(DownloadProgress(completedBytes: completed, totalBytes: total, attempt: attempt))
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let result: Error? = failure ?? error.map { error in
      let ns = error as NSError
      if ns.code == NSURLErrorTimedOut { return DownloadError.stalled }
      if ns.code == NSURLErrorCancelled { return CancellationError() }
      return DownloadError.network(ns.localizedDescription)
    }
    if let result { continuation?.resume(throwing: result) } else { continuation?.resume() }
    continuation = nil
  }
}
