import Foundation

/// The same task run on two models, saved with the session (#89).
public struct Comparison: Codable, Sendable, Equatable, Identifiable {
  public var id: UUID
  public var task: String
  public var createdAt: Date
  public var sides: [ComparisonSide]

  public init(id: UUID = UUID(), task: String, createdAt: Date = Date(), sides: [ComparisonSide] = []) {
    self.id = id
    self.task = task
    self.createdAt = createdAt
    self.sides = sides
  }
}

/// What one model did with the task, in its own copy of the project.
public struct ComparisonSide: Codable, Sendable, Equatable, Identifiable {
  public struct ToolCall: Codable, Sendable, Equatable {
    public var name: String
    public var detail: String
    /// completed, error, or blocked: <rule>.
    public var status: String

    public init(name: String, detail: String, status: String) {
      self.name = name
      self.detail = detail
      self.status = status
    }
  }

  public var id: String { modelId }
  public var modelId: String
  public var modelName: String
  public var answer: String
  public var tools: [ToolCall]
  public var seconds: Double
  /// As reported by the harness; nil when it did not report them, never estimated.
  public var inputTokens: Int?
  public var outputTokens: Int?
  /// Files the agent added, changed or deleted in its copy, relative to the project ("+ new.txt", "~ a.swift", "- old.md").
  public var filesChanged: [String]
  /// Why the run did not finish, if it did not.
  public var error: String?

  public init(
    modelId: String, modelName: String, answer: String = "", tools: [ToolCall] = [], seconds: Double = 0,
    inputTokens: Int? = nil, outputTokens: Int? = nil, filesChanged: [String] = [], error: String? = nil
  ) {
    self.modelId = modelId
    self.modelName = modelName
    self.answer = answer
    self.tools = tools
    self.seconds = seconds
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.filesChanged = filesChanged
    self.error = error
  }
}

public enum ComparisonError: Error, Equatable, CustomStringConvertible {
  case tooManyFiles(Int)

  public var description: String {
    switch self {
    case .tooManyFiles(let limit):
      "The project has more than \(limit) files, too many to copy for a comparison. Compare in a smaller project."
    }
  }
}

/// A private copy of a project for one side of a comparison, so both models start from the same state
/// and nothing they do reaches the real project. On APFS the copy is a clone: it takes no extra space
/// until a file is changed.
public struct ProjectCopy: Sendable {
  /// Files compared before and after a run. A project above this is refused rather than copied slowly.
  public static let fileLimit = 50_000

  public let folder: URL
  let before: [String: FileStamp]

  struct FileStamp: Equatable {
    var size: Int
    var modified: Date
  }

  /// Copies `project` into a new folder under `scratch`. The copy's last path component is the project's
  /// name, so the agent sees the same folder name.
  public static func make(of project: URL, in scratch: URL) throws -> ProjectCopy {
    let original = try stamps(project)
    let parent = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let folder = parent.appendingPathComponent(project.lastPathComponent, isDirectory: true)
    do {
      try FileManager.default.copyItem(at: project, to: folder)
    } catch {
      try? FileManager.default.removeItem(at: parent)
      throw error
    }
    return ProjectCopy(folder: folder, before: original)
  }

  /// What changed in the copy since it was made, sorted: "+ added", "~ changed", "- deleted".
  public func changes() throws -> [String] {
    let after = try Self.stamps(folder)
    var lines: [String] = []
    for path in Set(before.keys).union(after.keys).sorted() {
      switch (before[path], after[path]) {
      case (nil, _?): lines.append("+ \(path)")
      case (_?, nil): lines.append("- \(path)")
      case (let a?, let b?) where a != b: lines.append("~ \(path)")
      default: break
      }
    }
    return lines
  }

  /// Removes the copy.
  public func discard() {
    try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
  }

  /// Size and modification time of every regular file, by relative path. Git's own folder is skipped:
  /// a change there is not a change to the project.
  static func stamps(_ root: URL, limit: Int = fileLimit) throws -> [String: FileStamp] {
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [:] }
    let base = root.resolvingSymlinksInPath().path
    var result: [String: FileStamp] = [:]
    while let url = walker.nextObject() as? URL {
      if url.lastPathComponent == ".git" { walker.skipDescendants(); continue }
      let values = try url.resourceValues(forKeys: Set(keys))
      guard values.isRegularFile == true else { continue }
      guard result.count < limit else { throw ComparisonError.tooManyFiles(limit) }
      let path = url.resolvingSymlinksInPath().path
      let relative = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : url.lastPathComponent
      result[relative] = FileStamp(size: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast)
    }
    return result
  }
}

extension AgentClient {
  /// Input and output tokens of a harness session, summed over its assistant messages, as the harness
  /// reports them. Nil when no message carries a count.
  public func tokens(session: String) async throws -> (input: Int, output: Int)? {
    struct Message: Decodable {
      struct Info: Decodable {
        struct Tokens: Decodable { var input: Int?; var output: Int? }
        var role: String?
        var tokens: Tokens?
      }
      var info: Info
    }
    let (data, response) = try await URLSession.shared.data(for: request("GET", "session/\(session)/message"))
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw AgentError.malformed }
    let messages = try JSONDecoder().decode([Message].self, from: data)
    let counted = messages.filter { $0.info.role == "assistant" }.compactMap(\.info.tokens)
    guard !counted.isEmpty else { return nil }
    return (counted.compactMap(\.input).reduce(0, +), counted.compactMap(\.output).reduce(0, +))
  }
}
