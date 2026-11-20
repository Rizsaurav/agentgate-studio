import CryptoKit
import Foundation

/// What re-checking an installed model's file found.
public enum Integrity: Sendable, Equatable {
  case intact
  /// The file is there but its size or checksum is not what was installed.
  case damaged(reason: String)
  case missing

  public var isDamaged: Bool { self != .intact }

  /// One line for the user.
  public func message(for model: InstalledModel) -> String {
    switch self {
    case .intact: "\(model.name): the model file is intact."
    case .damaged(let reason): "\(model.name): the model file is damaged (\(reason)). Reinstall it to fix this."
    case .missing: "\(model.name): the model file is missing. Reinstall it to fix this."
    }
  }
}

/// Re-hashes an installed model on demand. Never part of a normal load, so loading stays as fast as before.
public struct FileIntegrityCheck: Sendable {
  public let store: ModelStore

  public init(store: ModelStore) { self.store = store }

  /// Compares the file on disk with the size and SHA-256 recorded at install. Runs off the caller's thread,
  /// reports progress from 0 to 1, and stops when the task is cancelled.
  public func verify(
    _ model: InstalledModel, progress: @escaping @Sendable (Double) -> Void = { _ in }
  ) async throws -> Integrity {
    let url = store.fileURL(model)
    let work = Task.detached(priority: .utility) {
      try Self.check(url: url, bytes: model.bytes, sha256: model.sha256, progress: progress)
    }
    return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
  }

  static func check(
    url: URL, bytes: UInt64, sha256: String, progress: @Sendable (Double) -> Void
  ) throws -> Integrity {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = (attributes[.size] as? NSNumber)?.uint64Value else { return .missing }
    guard size == bytes else {
      return .damaged(reason: "it is \(size) bytes, \(bytes) were installed")
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    var read: UInt64 = 0
    var reported = -1
    while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
      try Task.checkCancellation()
      hasher.update(data: chunk)
      read += UInt64(chunk.count)
      let percent = bytes == 0 ? 100 : Int(read * 100 / bytes)
      if percent != reported {
        reported = percent
        progress(Double(percent) / 100)
      }
    }
    let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return actual == sha256.lowercased() ? .intact : .damaged(reason: "its checksum does not match")
  }
}
