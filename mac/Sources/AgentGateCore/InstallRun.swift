import Foundation

/// The record of one install, saved as it goes, so a quit or crash does not lose where it was.
/// Steps are safe to repeat: a download resumes from its partial file and is checked again.
public struct InstallRun: Codable, Sendable, Equatable, Identifiable {
  public var id: String { modelId }
  public var modelId: String
  public var modelName: String
  public var startedAt: Date
  public var updatedAt: Date
  public var step: InstallStep
  /// What each step reported, for the dialogs behind the step dots. Messages only, never keys or prompts.
  public var log: [InstallStep: [String]]
  /// Set when the install stopped with an error, so the bar can say so instead of offering a silent resume.
  public var failure: String?

  public init(modelId: String, modelName: String, startedAt: Date = Date()) {
    self.modelId = modelId
    self.modelName = modelName
    self.startedAt = startedAt
    self.updatedAt = startedAt
    self.step = .hardware
    self.log = [:]
  }

  /// Adds a step message. Download progress replaces its own last line instead of piling up.
  public mutating func record(_ update: InstallUpdate, at date: Date = Date()) {
    step = update.step
    updatedAt = date
    var lines = log[update.step, default: []]
    if update.step == .download, update.totalBytes > 0, let last = lines.last, last.hasPrefix("Downloading ") {
      lines[lines.count - 1] = update.message
    } else if lines.last != update.message {
      lines.append(update.message)
    }
    log[update.step] = Array(lines.suffix(40))
  }
}

/// Install runs on disk: one small private file per model, removed when the install finishes or is discarded.
public struct InstallRunStore: Sendable {
  public let folder: URL

  public init(folder: URL = AppPaths.support.appendingPathComponent("runs", isDirectory: true)) { self.folder = folder }

  private func file(_ id: String) -> URL { folder.appendingPathComponent("\(id).json") }

  public func save(_ run: InstallRun) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(run).write(to: file(run.modelId), options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(run.modelId).path)
  }

  /// Unfinished runs, newest first. A run for a model that is now installed is finished and is cleaned up.
  public func unfinished(installed: Set<String>) -> [InstallRun] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var runs: [InstallRun] = []
    for name in names where name.hasSuffix(".json") {
      guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
            let run = try? decoder.decode(InstallRun.self, from: data) else { continue }
      if installed.contains(run.modelId) { remove(run.modelId) } else { runs.append(run) }
    }
    return runs.sorted { $0.updatedAt > $1.updatedAt }
  }

  public func remove(_ id: String) {
    try? FileManager.default.removeItem(at: file(id))
  }
}
extension InstallStep: CodingKeyRepresentable {}
