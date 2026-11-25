import Foundation

/// Our check of every tool call before it runs, on top of OpenCode's own argument schemas and the
/// sandbox: paths inside the project, sane sizes, and command rules. Reads, globs and greps go
/// through it too, not only the calls that ask the user.
///
/// A refusal carries a message written for the model, so it can correct the call and go on
/// instead of stopping: what was wrong and what to do instead.
public enum ToolCallCheck {
  public struct Rejection: Sendable, Equatable {
    /// Short name for the Security log.
    public var rule: String
    /// Sent back to the model as the reason the call was refused.
    public var message: String
  }

  /// Tools that only look at the project: when the check passes they run without asking the user.
  public static let readOnly: Set<String> = ["read", "glob", "grep", "list", "lsp"]
  static let fileTools: Set<String> = ["edit", "write", "patch", "multiedit"]
  static let known: Set<String> = readOnly.union(fileTools).union(["bash", "webfetch", "websearch", "external_directory", "todowrite", "todoread", "task", "skill"])
  static let maxQueryLength = 500
  static let maxURLLength = 2048

  static let maxPathLength = 1024
  static let maxPatternLength = 500
  static let maxCommandLength = 10_000
  static let maxPaths = 50

  /// Nil when the call may go on to the permission gate (or, for a read-only tool, simply run).
  public static func check(
    _ call: AgentEvent.Permission, folder: URL, capabilities: AgentCapabilities = AgentCapabilities()
  ) -> Rejection? {
    let tool = call.tool
    guard !tool.isEmpty, tool.count <= 64, tool.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
      return Rejection(rule: "malformed-call", message: "The tool name is not valid. Use one of the tools you were given.")
    }
    guard known.contains(tool) || capabilities.isMCPTool(tool) else {
      return Rejection(rule: "unknown-tool", message: "The tool \"\(tool)\" is not available here. Use read, glob, grep, list, edit, write or bash.")
    }
    for text in [call.detail, call.path ?? ""] where text.contains("\0") {
      return Rejection(rule: "malformed-call", message: "\(tool): the arguments contain a NUL character. Send plain text.")
    }
    switch tool {
    case "webfetch":
      return url(call.detail)
    case "websearch":
      let query = call.detail.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !query.isEmpty else { return Rejection(rule: "malformed-call", message: "websearch: the query is empty. Say what to search for.") }
      guard query.count <= maxQueryLength else {
        return Rejection(rule: "too-large", message: "websearch: the query is longer than \(maxQueryLength) characters. Search for something shorter.")
      }
      return nil
    case "lsp":
      return inside(tool, call.path ?? (call.detail.isEmpty ? "." : call.detail), folder: folder)
    case "read", "list":
      guard !call.detail.trimmingCharacters(in: .whitespaces).isEmpty || tool == "list" else {
        return Rejection(rule: "malformed-call", message: "read: filePath is missing. Give the path of a file inside the project.")
      }
      return inside(tool, call.detail.isEmpty ? "." : call.detail, folder: folder)
    case "glob", "grep":
      let pattern = call.detail
      guard !pattern.isEmpty else {
        return Rejection(rule: "malformed-call", message: "\(tool): pattern is missing. Give a \(tool == "glob" ? "file pattern such as **/*.swift" : "text or regular expression to search for").")
      }
      guard pattern.count <= maxPatternLength else {
        return Rejection(rule: "too-large", message: "\(tool): the pattern is longer than \(maxPatternLength) characters. Use a shorter pattern.")
      }
      if tool == "glob", pattern.hasPrefix("/") || pattern.hasPrefix("~") || pattern.split(separator: "/").contains("..") {
        return Rejection(rule: "outside-project", message: "glob: the pattern \"\(pattern)\" reaches outside the project. Use a pattern relative to the project root, without .. or an absolute path.")
      }
      if let path = call.path, !path.isEmpty { return inside(tool, path, folder: folder) }
      return nil
    case "bash":
      let command = call.detail.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !command.isEmpty else {
        return Rejection(rule: "malformed-call", message: "bash: the command is empty. Give the command to run.")
      }
      guard command.count <= maxCommandLength else {
        return Rejection(rule: "too-large", message: "bash: the command is longer than \(maxCommandLength) characters. Write a script file in the project and run that instead.")
      }
      return nil
    case _ where fileTools.contains(tool):
      let paths = call.detail.components(separatedBy: ", ").filter { !$0.isEmpty }
      guard paths.count <= maxPaths else {
        return Rejection(rule: "too-large", message: "\(tool): \(paths.count) files in one call is too many. Change at most \(maxPaths) files per call.")
      }
      for path in paths {
        if let rejection = inside(tool, path, folder: folder) { return rejection }
      }
      return nil
    default:
      return nil
    }
  }

  /// A page the agent may fetch: http or https on a public host. Loopback, private and link-local addresses are
  /// refused, so a fetch cannot reach the local model engine, the harness or other machines on the network.
  static func url(_ text: String) -> Rejection? {
    let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard raw.count <= maxURLLength, let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
          ["http", "https"].contains(scheme), let host = url.host?.lowercased(), !host.isEmpty else {
      return Rejection(rule: "malformed-call", message: "webfetch: give one full http or https address.")
    }
    if isPrivate(host: host) {
      return Rejection(rule: "private-address", message: "webfetch: \"\(host)\" is this Mac or a private network, which the agent may not reach. Fetch a public page.")
    }
    return nil
  }

  static func isPrivate(host: String) -> Bool {
    let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if ["localhost", "0.0.0.0", "::", "::1"].contains(name) || name.hasSuffix(".localhost") || name.hasSuffix(".local")
      || name.hasSuffix(".internal") || !name.contains(".") && !name.contains(":") { return true }
    let parts = name.split(separator: ".").compactMap { Int($0) }
    if parts.count == 4 {
      switch (parts[0], parts[1]) {
      case (127, _), (10, _), (0, _), (169, 254), (192, 168): return true
      case (172, let b) where (16...31).contains(b): return true
      case (100, let b) where (64...127).contains(b): return true
      default: return false
      }
    }
    if name.contains(":") {
      let lower = name.lowercased()
      return lower.hasPrefix("fe80") || lower.hasPrefix("fc") || lower.hasPrefix("fd") || lower.hasPrefix("::ffff:")
    }
    return false
  }

  /// Refuses a path that is too long, outside the project (after resolving .. and symlinks) or a key file.
  static func inside(_ tool: String, _ path: String, folder: URL) -> Rejection? {
    guard path.count <= maxPathLength else {
      return Rejection(rule: "too-large", message: "\(tool): the path is longer than \(maxPathLength) characters.")
    }
    let policyTool = tool == "read" || tool == "list" || tool == "glob" || tool == "grep" ? "read" : "edit"
    guard case .block(let rule, _) = ToolPolicy.evaluate(tool: policyTool, detail: path, folder: folder) else { return nil }
    if rule == "outside-project" {
      return Rejection(rule: rule, message: "\(tool): \"\(path)\" is outside the project folder. Use a path inside the project, relative to its root.")
    }
    return Rejection(rule: rule, message: "\(tool): \"\(path)\" holds keys or credentials, which the agent may not open. Work without it.")
  }
}
