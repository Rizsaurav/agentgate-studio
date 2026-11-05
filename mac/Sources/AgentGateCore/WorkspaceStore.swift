import Foundation

public struct Project: Codable, Sendable, Equatable, Identifiable, Hashable {
  public var id: UUID
  public var name: String
  public var createdAt: Date
  /// The folder on this Mac the agent works in. Nil for projects made before folders existed.
  public var folder: String?
  /// What the agents may do in this project. Nil (projects made before this existed) means full.
  public var access: ProjectAccess?

  public var effectiveAccess: ProjectAccess { access ?? .full }

  public init(id: UUID, name: String, createdAt: Date, folder: String? = nil, access: ProjectAccess? = nil) {
    self.id = id
    self.name = name
    self.createdAt = createdAt
    self.folder = folder
    self.access = access
  }
}

public struct Session: Codable, Sendable, Equatable, Identifiable {
  public var id: UUID
  public var projectId: UUID
  public var modelId: String
  public var modelName: String
  public var createdAt: Date
  public var messages: [ChatMessage]
  /// The harness's id for this conversation, so it continues after a restart.
  public var agentSession: String?

  public init(id: UUID, projectId: UUID, modelId: String, modelName: String, createdAt: Date, messages: [ChatMessage]) {
    self.id = id
    self.projectId = projectId
    self.modelId = modelId
    self.modelName = modelName
    self.createdAt = createdAt
    self.messages = messages
  }
}

public enum WorkspaceError: Error, Equatable, CustomStringConvertible {
  case invalidName

  public var description: String {
    switch self {
    case .invalidName: "Use a project name of 1 to 80 characters."
    }
  }
}

/// Projects and sessions saved on this Mac, in one JSON file written atomically.
///
/// Interim: the TypeScript harness owns projects and sessions. Once it runs inside the app (#65),
/// this store is replaced by calls to it and removed.
public struct WorkspaceStore: Sendable {
  public struct Snapshot: Codable, Sendable, Equatable {
    public var projects: [Project] = []
    public var sessions: [Session] = []

    public init(projects: [Project] = [], sessions: [Session] = []) {
      self.projects = projects
      self.sessions = sessions
    }
  }

  public let file: URL

  public init(file: URL = AppPaths.support.appendingPathComponent("workspace.json")) { self.file = file }

  public func load() throws -> Snapshot {
    guard FileManager.default.fileExists(atPath: file.path) else { return Snapshot() }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Snapshot.self, from: Data(contentsOf: file))
  }

  public func save(_ snapshot: Snapshot) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(snapshot).write(to: file, options: [.atomic])
    // Conversations are private: readable by this user only.
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }

  public static func validName(_ name: String) throws -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...80).contains(trimmed.count) else { throw WorkspaceError.invalidName }
    return trimmed
  }
}
