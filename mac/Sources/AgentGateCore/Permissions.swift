import Foundation

/// What an agent action would do, in the terms the user approves.
public enum ActionKind: String, Codable, Sendable, CaseIterable {
  case read, write, delete, install, network, shell
}

/// One thing the agent asks to do: the engine's tool name and its command or comma-separated paths.
public struct ActionRequest: Sendable, Equatable {
  public var tool: String
  public var detail: String

  public init(tool: String, detail: String) {
    self.tool = tool
    self.detail = detail
  }
}

/// What a request does, how to say it, and what an approval for it covers.
public struct Classification: Sendable, Equatable {
  public var kinds: Set<ActionKind>
  /// Deletes, force pushes and history rewrites: these ask every time, whatever was approved before.
  public var destructive: Bool
  /// One or two plain sentences for the approval prompt.
  public var summary: String
  /// What "for this session", "always" and "never" apply to. Same key, same kind of action.
  public var key: String
}

/// Sorts agent actions into reads, writes, deletes, installs, network use and shell commands.
public enum PermissionClassifier {
  static let readTools: Set<String> = ["read", "list", "glob", "grep", "ls", "lsp", "todoread"]
  static let writeTools: Set<String> = ["edit", "write", "patch", "multiedit", "todowrite"]

  static let deletePrograms: Set<String> = ["rm", "rmdir", "unlink", "shred", "trash", "srm"]
  static let writePrograms: Set<String> = ["touch", "mkdir", "cp", "mv", "tee", "ln", "install", "chmod", "truncate"]
  static let networkPrograms: Set<String> = [
    "curl", "wget", "http", "https", "ping", "dig", "nslookup", "host", "gh", "scp", "rsync", "ssh",
  ]
  /// Package managers and the subcommands that fetch from the network and change the project.
  static let installCommands: [String: Set<String>] = [
    "npm": ["install", "i", "ci", "add", "update", "upgrade", "exec", "x"],
    "npx": ["*"], "pnpm": ["install", "i", "add", "update", "up", "dlx"], "pnpx": ["*"],
    "yarn": ["install", "add", "upgrade", "up", "dlx", ""], "bun": ["install", "i", "add", "update", "x"], "bunx": ["*"],
    "pip": ["install", "download"], "pip3": ["install", "download"], "uv": ["add", "sync", "pip", "tool", "run"],
    "uvx": ["*"], "poetry": ["install", "add", "update"], "pipx": ["install", "run"],
    "brew": ["install", "upgrade", "reinstall", "tap", "update"], "gem": ["install", "update"],
    "bundle": ["install", "update", "add"], "cargo": ["install", "add", "update", "fetch"],
    "go": ["get", "install"], "composer": ["install", "require", "update"], "pod": ["install", "update"],
    "swift": ["package"],
  ]
  static let gitNetwork: Set<String> = ["clone", "fetch", "pull", "push", "ls-remote", "submodule"]
  static let gitWrite: Set<String> = [
    "add", "commit", "checkout", "switch", "merge", "rebase", "stash", "reset", "restore", "apply", "am",
    "cherry-pick", "revert", "tag", "branch", "mv", "init", "pull", "clone",
  ]

  public static func classify(_ request: ActionRequest) -> Classification {
    let tool = request.tool.lowercased()
    if readTools.contains(tool) {
      return Classification(
        kinds: [.read], destructive: false, summary: "Read \(short(request.detail)) in the project.", key: "read")
    }
    if writeTools.contains(tool) {
      let files = request.detail.components(separatedBy: ", ").filter { !$0.isEmpty }
      let what = files.count == 1 ? short(files[0]) : "\(files.count) files"
      return Classification(
        kinds: [.write], destructive: false, summary: "Change \(what) in the project.", key: "write:project")
    }
    if tool == "webfetch" || tool == "websearch" {
      return Classification(
        kinds: [.network], destructive: false, summary: "Fetch \(short(request.detail)) from the internet.",
        key: "network:\(tool)")
    }
    if tool == "bash" { return classifyCommand(request.detail) }
    // An unknown tool is treated as the most powerful kind: it asks, and approvals are kept separate.
    return Classification(
      kinds: [.shell], destructive: false, summary: "Use the tool \(short(tool)): \(short(request.detail)).",
      key: "tool:\(tool)")
  }

  static func classifyCommand(_ command: String) -> Classification {
    var kinds: Set<ActionKind> = [.shell]
    var destructive = false
    var programs: [String] = []
    let segments = ToolPolicy.split(command) ?? [command.split(separator: " ").map(String.init)]
    for words in segments {
      guard let first = words.first else { continue }
      let name = (first as NSString).lastPathComponent
      let args = Array(words.dropFirst())
      // "2>&1" splits into a word "1": a file descriptor, not a program.
      if name.allSatisfy(\.isNumber) { continue }
      if !programs.contains(name) { programs.append(name) }
      let sub = args.first(where: { !$0.hasPrefix("-") }) ?? ""
      if deletePrograms.contains(name) {
        kinds.insert(.delete)
        destructive = true
      }
      if writePrograms.contains(name) { kinds.insert(.write) }
      if name == "sed" && args.contains(where: { $0 == "-i" || $0.hasPrefix("-i") }) { kinds.insert(.write) }
      if networkPrograms.contains(name) { kinds.insert(.network) }
      if let subs = installCommands[name], subs.contains("*") || subs.contains(sub) {
        kinds.formUnion([.install, .network, .write])
      }
      if name == "find" && args.contains(where: { $0 == "-delete" || $0 == "-exec" || $0 == "-execdir" }) {
        kinds.insert(.delete)
        destructive = true
      }
      if name == "git" {
        if gitNetwork.contains(sub) { kinds.insert(.network) }
        if gitWrite.contains(sub) { kinds.insert(.write) }
        if isDestructiveGit(sub: sub, args: args) {
          kinds.insert(.delete)
          destructive = true
        }
      }
    }
    // A redirect into a file writes (or overwrites) it; "2>&1" and "> /dev/null" do not.
    let redirects = command.replacingOccurrences(
      of: #"[0-9]*>{1,2}\s*(/dev/null|&[0-9-])"#, with: "", options: .regularExpression)
    if redirects.range(of: #">{1,2}\s*[^\s]"#, options: .regularExpression) != nil {
      kinds.insert(.write)
    }
    var effects: [String] = []
    if kinds.contains(.delete) { effects.append("deletes files or history") }
    if kinds.contains(.install) { effects.append("installs packages") }
    if kinds.contains(.network) && !kinds.contains(.install) { effects.append("uses the internet") }
    if kinds.contains(.write) && !kinds.contains(.delete) && !kinds.contains(.install) {
      effects.append("changes files")
    }
    var summary = "Run “\(short(command, limit: 160))” in the project."
    if !effects.isEmpty { summary += " It \(join(effects))." }
    if destructive { summary += " This cannot be undone." }
    let key = "shell:" + programs.sorted().joined(separator: "+")
    return Classification(kinds: kinds, destructive: destructive, summary: summary, key: key)
  }

  static func isDestructiveGit(sub: String, args: [String]) -> Bool {
    switch sub {
    case "push":
      return args.contains(where: { $0 == "-f" || $0.hasPrefix("--force") || $0 == "--delete" || $0 == "-d" || $0.hasPrefix("+") || $0.hasPrefix(":") })
    case "reset": return args.contains("--hard")
    case "clean": return args.contains(where: { $0.hasPrefix("-") && $0.contains("f") })
    case "branch": return args.contains(where: { $0 == "-D" || $0 == "--delete" || $0 == "-d" })
    case "checkout", "restore": return args.contains("--") || args.contains(".") || args.contains("--staged")
    case "rm", "filter-branch", "filter-repo": return true
    case "stash": return args.contains("drop") || args.contains("clear")
    case "rebase": return args.contains("-i") || args.contains("--interactive") || args.contains("--onto")
    default: return false
    }
  }

  static func short(_ text: String, limit: Int = 80) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " ")
    return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
  }

  static func join(_ parts: [String]) -> String {
    parts.count <= 1 ? parts.joined() : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
  }
}

/// How the user answered an approval prompt.
public enum ApprovalChoice: String, Codable, Sendable, CaseIterable {
  case once, session, always, never
}

/// A remembered answer for one kind of action in one project: "always" or "never".
public struct Grant: Codable, Sendable, Equatable, Identifiable {
  public var id: UUID
  public var key: String
  /// How it was described when the user answered, for the list in settings.
  public var summary: String
  public var allow: Bool
  public var date: Date

  public init(id: UUID = UUID(), key: String, summary: String, allow: Bool, date: Date = Date()) {
    self.id = id
    self.key = key
    self.summary = summary
    self.allow = allow
    self.date = date
  }
}

public enum PermissionError: Error, Equatable, CustomStringConvertible {
  case unreadable(String)

  public var description: String {
    switch self {
    case .unreadable(let file): "The saved permissions in \(file) could not be read, so nothing is allowed until they are reset."
    }
  }
}

/// The remembered answers of one project, in a private (0600) file. A file that exists but cannot be
/// read is an error, never an empty list: the gate then refuses everything (fail closed).
public struct ApprovalStore: Sendable {
  private static let lock = NSLock()
  public let file: URL

  public init(project: UUID, directory: URL = AppPaths.support.appendingPathComponent("permissions", isDirectory: true)) {
    file = directory.appendingPathComponent("\(project.uuidString).json")
  }

  public init(file: URL) { self.file = file }

  public func grants() throws -> [Grant] { try Self.lock.withLock { try read() } }

  /// Remembers an answer, replacing any earlier answer for the same kind of action.
  public func remember(_ grant: Grant) throws {
    try Self.lock.withLock {
      try write(try read().filter { $0.key != grant.key } + [grant])
    }
  }

  /// Takes back a remembered answer: the next request of that kind asks again.
  public func revoke(_ id: UUID) throws {
    try Self.lock.withLock { try write(try read().filter { $0.id != id }) }
  }

  /// Forgets every answer, including a file that could not be read.
  public func reset() throws {
    try Self.lock.withLock {
      if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
  }

  private func read() throws -> [Grant] {
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
      return try decoder.decode([Grant].self, from: Data(contentsOf: file))
    } catch {
      throw PermissionError.unreadable(file.lastPathComponent)
    }
  }

  private func write(_ grants: [Grant]) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(grants).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
}

/// The permission decision for one agent session. Checked by the app, not left to the prompt:
/// hard rules first, then remembered answers, and anything uncertain is refused. Commands that are
/// allowed still run inside `AgentSandbox`.
public final class PermissionGate: @unchecked Sendable {
  public enum Decision: Sendable, Equatable {
    case allow
    case deny(rule: String, reason: String)
    /// Show this to the user. `choices` leaves out "session" and "always" for destructive actions.
    case ask(Prompt)
  }

  public struct Prompt: Sendable, Equatable {
    public var request: ActionRequest
    public var classification: Classification
    public var choices: [ApprovalChoice]
  }

  public let folder: URL
  public let store: ApprovalStore
  private let lock = NSLock()
  private var sessionKeys: Set<String> = []

  public init(folder: URL, store: ApprovalStore) {
    self.folder = folder
    self.store = store
  }

  public func decide(_ request: ActionRequest) -> Decision {
    let policyTool = PermissionClassifier.writeTools.contains(request.tool) ? "edit" : request.tool
    if case .block(let rule, let reason) = ToolPolicy.evaluate(tool: policyTool, detail: request.detail, folder: folder) {
      return .deny(rule: rule, reason: reason)
    }
    let classification = PermissionClassifier.classify(request)
    if classification.kinds == [.read] { return .allow }
    let grants: [Grant]
    do {
      grants = try store.grants()
    } catch {
      return .deny(rule: "permission-state-unknown", reason: "\(error)")
    }
    if let grant = grants.first(where: { $0.key == classification.key }), !grant.allow {
      return .deny(rule: "denied-by-user", reason: "You chose never to allow this in this project.")
    }
    if classification.destructive {
      return .ask(Prompt(request: request, classification: classification, choices: [.once, .never]))
    }
    if grants.contains(where: { $0.key == classification.key && $0.allow }) { return .allow }
    if lock.withLock({ sessionKeys.contains(classification.key) }) { return .allow }
    return .ask(Prompt(request: request, classification: classification, choices: ApprovalChoice.allCases))
  }

  /// Applies the user's answer. Returns whether this request may run now. A choice the prompt did not
  /// offer (such as "always" for a delete) is refused rather than widened.
  @discardableResult
  public func answer(_ prompt: Prompt, with choice: ApprovalChoice?) throws -> Bool {
    guard let choice, prompt.choices.contains(choice) else { return false }
    let classification = prompt.classification
    switch choice {
    case .once:
      return true
    case .session:
      lock.withLock { _ = sessionKeys.insert(classification.key) }
      return true
    case .always, .never:
      try store.remember(Grant(key: classification.key, summary: classification.summary, allow: choice == .always))
      return choice == .always
    }
  }

  /// Waits for the user's answer, but never longer than `timeout`. No answer (no window to show the
  /// prompt, the app is closing, the user is away) is nil, which `answer` turns into a refusal.
  public static func waitForAnswer(
    within timeout: Duration, _ ask: @escaping @Sendable () async -> ApprovalChoice?
  ) async -> ApprovalChoice? {
    await withTaskGroup(of: ApprovalChoice?.self) { group in
      group.addTask { await ask() }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }
}
