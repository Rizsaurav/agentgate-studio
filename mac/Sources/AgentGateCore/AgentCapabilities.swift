import Foundation

/// What the agent may do beyond reading, editing and running commands. Everything starts off: each capability
/// adds tool descriptions the local model reads before every first answer, and some reach the network, so the
/// user turns on only what they use. Saved on this Mac (0600), never in a project.
public struct AgentCapabilities: Codable, Sendable, Equatable {
  /// A to-do list the agent keeps for tasks with several steps, shown as a checklist in the chat.
  public var todos = false
  /// The agent may hand a part of the task to a helper agent with its own context, in the background.
  public var subagents = false
  /// Reusable instructions in the project's `.agents/skills/<name>/SKILL.md`, loaded only when relevant.
  public var skills = false
  /// Definitions, references and hover docs from the language servers already installed on this Mac.
  public var codeNavigation = false
  /// The agent may fetch a web page the user approves. Sends the URL to that site.
  public var webFetch = false
  /// The agent may search the web through Exa. Sends the query to Exa, a third party.
  public var webSearch = false
  /// Local Model Context Protocol servers whose tools the agent may call, each call approved by the user.
  public var mcpServers: [MCPServer] = []

  public init() {}

  /// One MCP server: a command the harness starts on this Mac, inside the same sandbox as the agent.
  public struct MCPServer: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    /// Lowercase letters, digits and dashes; tool names are `<name>_<tool>`.
    public var name: String
    public var command: [String]
    public var enabled = true

    public init(name: String, command: [String], enabled: Bool = true) {
      self.name = name
      self.command = command
      self.enabled = enabled
    }

    public static func isValidName(_ name: String) -> Bool {
      !name.isEmpty && name.count <= 32 && name.first?.isLetter == true
        && name.allSatisfy { ($0.isLowercase && $0.isASCII) || $0.isNumber || $0 == "-" }
    }
  }

  public var activeServers: [MCPServer] {
    mcpServers.filter { $0.enabled && MCPServer.isValidName($0.name) && !$0.command.isEmpty }
  }

  /// Harness tools this set turns on. Everything else the harness offers stays off.
  public var enabledTools: Set<String> {
    var tools: Set<String> = []
    if todos { tools.insert("todowrite") }
    if subagents { tools.insert("task") }
    if skills { tools.insert("skill") }
    if codeNavigation { tools.insert("lsp") }
    if webFetch { tools.insert("webfetch") }
    if webSearch { tools.insert("websearch") }
    return tools
  }

  /// Harness switches that hold whatever the user chose: the project cannot change the agent's rules, the user's
  /// own assistant settings in the home folder stay out of it, nothing is downloaded behind the user's back, and a
  /// command that hangs is stopped instead of stalling the turn.
  public var environment: [String: String] {
    var env = [
      "OPENCODE_DISABLE_PROJECT_CONFIG": "1",
      "OPENCODE_DISABLE_CLAUDE_CODE": "1",
      "OPENCODE_DISABLE_EXTERNAL_SKILLS": "1",
      "OPENCODE_DISABLE_MODELS_FETCH": "1",
      "OPENCODE_DISABLE_LSP_DOWNLOAD": "1",
      "OPENCODE_DISABLE_AUTOUPDATE": "1",
      "OPENCODE_EXPERIMENTAL_BASH_DEFAULT_TIMEOUT_MS": String(Self.commandTimeout * 1000),
    ]
    if codeNavigation { env["OPENCODE_EXPERIMENTAL_LSP_TOOL"] = "1" }
    if webSearch { env["OPENCODE_ENABLE_EXA"] = "1" }
    if subagents { env["OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS"] = "1" }
    return env
  }

  /// Seconds a command may run before the harness stops it and tells the model it timed out.
  public static let commandTimeout = 300

  /// Tool names the gate accepts from MCP servers: `<server>_<tool>`.
  public func isMCPTool(_ name: String) -> Bool {
    activeServers.contains { name.hasPrefix($0.name + "_") || name.hasPrefix($0.name.replacingOccurrences(of: "-", with: "_") + "_") }
  }

  private enum CodingKeys: String, CodingKey {
    case todos, subagents, skills, codeNavigation, webFetch, webSearch, mcpServers
  }

  /// Missing keys keep their defaults, so a file saved by an older version still loads.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    todos = try c.decodeIfPresent(Bool.self, forKey: .todos) ?? false
    subagents = try c.decodeIfPresent(Bool.self, forKey: .subagents) ?? false
    skills = try c.decodeIfPresent(Bool.self, forKey: .skills) ?? false
    codeNavigation = try c.decodeIfPresent(Bool.self, forKey: .codeNavigation) ?? false
    webFetch = try c.decodeIfPresent(Bool.self, forKey: .webFetch) ?? false
    webSearch = try c.decodeIfPresent(Bool.self, forKey: .webSearch) ?? false
    mcpServers = try c.decodeIfPresent([MCPServer].self, forKey: .mcpServers) ?? []
  }
}

extension JSONEncoder {
  static var sorted: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}

/// The capabilities on disk.
public struct CapabilityStore: Sendable {
  public let file: URL

  public init(file: URL = AppPaths.support.appendingPathComponent("capabilities.json")) {
    self.file = file
  }

  public func load() -> AgentCapabilities {
    guard let data = try? Data(contentsOf: file) else { return AgentCapabilities() }
    return (try? JSONDecoder().decode(AgentCapabilities.self, from: data)) ?? AgentCapabilities()
  }

  public func save(_ capabilities: AgentCapabilities) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder.sorted.encode(capabilities).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
}

/// Splits a command line typed by the user into words, the way a shell would for plain arguments: spaces
/// separate words, and single or double quotes keep spaces inside one word. No variables, globs or escapes.
public enum CommandLineWords {
  public static func split(_ line: String) -> [String] {
    var words: [String] = []
    var current = ""
    var quote: Character?
    var inWord = false
    for char in line {
      if let open = quote {
        if char == open { quote = nil } else { current.append(char) }
      } else if char == "\"" || char == "'" {
        quote = char
        inWord = true
      } else if char.isWhitespace {
        if inWord { words.append(current); current = ""; inWord = false }
      } else {
        current.append(char)
        inWord = true
      }
    }
    if inWord { words.append(current) }
    return words
  }
}
