import Foundation

/// What the agent harness reports while it works, reduced to what the app shows.
public enum AgentEvent: Sendable, Equatable {
  /// A message exists and who wrote it ("user" or "assistant").
  case message(id: String, role: String)
  /// The full text of one text part so far.
  case text(partID: String, messageID: String, text: String)
  /// More text for an existing part (an answer or reasoning part).
  case textDelta(partID: String, messageID: String, delta: String)
  /// The model's reasoning so far, shown apart from the answer.
  case reasoning(partID: String, messageID: String, text: String)
  /// A tool call and where it stands: pending, running, completed or error.
  case tool(Tool)
  /// The harness wants the user's yes or no before running something.
  case permission(Permission)
  /// One model call finished, with the engine's token counts; nil when the engine reported none.
  case usage(partID: String, TokenUsage?)
  /// The harness summarised older turns to fit the context.
  case compacted(partID: String)
  /// A question was answered, by the user, the app, or the harness itself cancelling it.
  case permissionReplied(id: String)
  case busy
  case idle
  /// The event stream is open; nothing before this point can be missed.
  case connected
  case failed(String)

  public struct Tool: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var status: String
    /// The command or path, as written by the model.
    public var detail: String
    /// What the tool printed. While a command runs this is its output so far.
    public var output: String
    /// The harness's id for this call, which a question about it names.
    public var callID: String?
    /// The harness's one-line title for the call, once it has one.
    public var title: String?
    /// The model's own explanation of a command ("Runs the tests").
    public var purpose: String?
    /// A command's exit status, once it has ended.
    public var exitCode: Int?
    /// An edit as a unified diff.
    public var diff: String?
    /// Why the call failed, for status "error".
    public var error: String?
    public var started: Date?
    public var ended: Date?
    /// The output was cut by the harness.
    public var truncated: Bool
    /// The agent's to-do list, for a todowrite call.
    public var todos: [TodoItem]?

    public init(
      id: String, name: String, status: String, detail: String, output: String, callID: String? = nil, title: String? = nil,
      purpose: String? = nil, exitCode: Int? = nil, diff: String? = nil, error: String? = nil,
      started: Date? = nil, ended: Date? = nil, truncated: Bool = false, todos: [TodoItem]? = nil
    ) {
      self.todos = todos
      self.id = id
      self.name = name
      self.status = status
      self.detail = detail
      self.output = output
      self.callID = callID
      self.title = title
      self.purpose = purpose
      self.exitCode = exitCode
      self.diff = diff
      self.error = error
      self.started = started
      self.ended = ended
      self.truncated = truncated
    }
  }

  public struct Permission: Sendable, Equatable, Identifiable {
    public var id: String
    public var tool: String
    public var detail: String
    /// The folder a glob or grep searches in, when the call names one.
    public var path: String?
    /// The tool call this question is about, when the harness says.
    public var callID: String?

    public init(id: String, tool: String, detail: String, path: String? = nil, callID: String? = nil) {
      self.id = id
      self.tool = tool
      self.detail = detail
      self.path = path
      self.callID = callID
    }
  }
}

/// A value that is dropped instead of failing the whole event when its shape is not the expected one.
struct Lenient<Value: Decodable>: Decodable {
  var value: Value?
  init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// The call a question is about.
struct CallRef: Decodable { var callID: String? }

/// Decodes the harness's event stream. Unknown events are ignored, so a newer harness cannot break the app.
enum AgentEventDecoder {
  private struct Envelope: Decodable {
    struct Properties: Decodable {
      struct Part: Decodable {
        struct State: Decodable {
          struct Input: Decodable {
            var command: String?
            var description: String?
            var filePath: String?
            var pattern: String?
            var path: String?
            var url: String?
            var query: String?
            var name: String?
            var todos: Lenient<[TodoItem]>?
          }
          struct Metadata: Decodable {
            var output: String?
            var exit: Int?
            var diff: String?
            var truncated: Bool?
          }
          struct Time: Decodable {
            var start: Double?
            var end: Double?
          }
          var status: String?
          var input: Input?
          var output: String?
          var title: String?
          var error: String?
          var metadata: Metadata?
          var time: Time?
        }
        var id: String?
        var messageID: String?
        var callID: String?
        var type: String
        var text: String?
        var tool: String?
        var state: State?
        var tokens: Tokens?
      }
      struct Tokens: Decodable {
        struct Cache: Decodable { var read: Int?; var write: Int? }
        var input: Int?
        var output: Int?
        var reasoning: Int?
        var cache: Cache?
      }
      struct Metadata: Decodable {
        var command: String?
        var path: String?
      }
      struct Status: Decodable { var type: String? }
      struct Failure: Decodable {
        struct Data: Decodable { var message: String? }
        var name: String?
        var data: Data?
      }
      struct Info: Decodable {
        var id: String?
        var role: String?
      }
      var info: Info?
      var part: Part?
      var partID: String?
      var messageID: String?
      var field: String?
      var delta: String?
      var id: String?
      var permission: String?
      var patterns: [String]?
      var metadata: Metadata?
      var status: Status?
      var error: Failure?
      var tool: Lenient<CallRef>?
      var requestID: String?
    }
    var type: String
    var properties: Properties
  }

  static func decode(_ json: Data) -> AgentEvent? {
    guard let event = try? JSONDecoder().decode(Envelope.self, from: json) else { return nil }
    let p = event.properties
    switch event.type {
    case "message.updated":
      guard let id = p.info?.id, let role = p.info?.role else { return nil }
      return .message(id: id, role: role)
    case "message.part.updated":
      guard let part = p.part, let id = part.id else { return nil }
      if part.type == "text", let text = part.text, let message = part.messageID {
        return .text(partID: id, messageID: message, text: text)
      }
      if part.type == "reasoning", let message = part.messageID {
        return .reasoning(partID: id, messageID: message, text: part.text ?? "")
      }
      if part.type == "tool", let name = part.tool {
        let state = part.state
        let input = state?.input
        let date = { (ms: Double?) in ms.map { Date(timeIntervalSince1970: $0 / 1000) } }
        return .tool(.init(
          id: id, name: name, status: state?.status ?? "pending",
          detail: input?.command ?? input?.filePath ?? input?.pattern ?? input?.url ?? input?.path ?? input?.query
            ?? input?.name ?? (name == "task" ? input?.description : nil) ?? "",
          // A running command reports its output so far in the metadata; the final output replaces it.
          output: state?.output ?? state?.metadata?.output ?? "", callID: part.callID,
          title: state?.title, purpose: input?.description, exitCode: state?.metadata?.exit,
          diff: state?.metadata?.diff, error: state?.error, started: date(state?.time?.start),
          ended: date(state?.time?.end), truncated: state?.metadata?.truncated ?? false, todos: input?.todos?.value))
      }
      if part.type == "compaction" { return .compacted(partID: id) }
      if part.type == "step-finish" {
        let t = part.tokens
        let prompt = (t?.input ?? 0) + (t?.cache?.read ?? 0) + (t?.cache?.write ?? 0)
        let generated = (t?.output ?? 0) + (t?.reasoning ?? 0)
        // All zero means the engine sent no usage; count the reply, not invented tokens.
        let usage = prompt == 0 && generated == 0 ? nil : TokenUsage.reported(prompt: prompt, generated: generated)
        return .usage(partID: id, usage)
      }
      return nil
    case "message.part.delta":
      guard p.field == "text", let id = p.partID, let message = p.messageID, let delta = p.delta else { return nil }
      return .textDelta(partID: id, messageID: message, delta: delta)
    case "permission.asked":
      guard let id = p.id, let tool = p.permission else { return nil }
      let detail = p.metadata?.command ?? (p.patterns ?? []).joined(separator: ", ")
      return .permission(.init(id: id, tool: tool, detail: detail, path: p.metadata?.path, callID: p.tool?.value?.callID))
    case "permission.replied":
      return p.requestID.map { .permissionReplied(id: $0) }
    case "session.status":
      return p.status?.type == "busy" ? .busy : nil
    case "session.idle":
      return .idle
    case "server.connected":
      return .connected
    case "session.error":
      return .failed(p.error?.data?.message ?? p.error?.name ?? "The agent stopped with an error.")
    default:
      return nil
    }
  }
}

public enum AgentError: Error, Equatable, CustomStringConvertible {
  case missingBinary(String)
  case startTimedOut(String)
  case http(Int)
  case malformed

  public var description: String {
    switch self {
    case .missingBinary(let path): "The agent harness is missing (\(path))."
    case .startTimedOut(let tail): "The agent harness did not start." + (tail.isEmpty ? "" : " Its last output: \(tail)")
    case .http(let code): "The agent harness answered with HTTP \(code)."
    case .malformed: "The agent harness sent a reply that could not be read."
    }
  }
}

/// The bundled OpenCode harness, running on loopback behind a per-launch password, working in one
/// project folder and talking to one local model. Terminal commands and edits ask first.
public final class AgentServer: @unchecked Sendable {
  public let baseURL: URL
  let password: String
  public let folder: URL
  /// The engine key it was started for, so the app can tell when it must restart.
  public let engineKey: String
  /// What the harness was started with, so the app can tell when a change needs a restart.
  public let capabilities: AgentCapabilities
  private let process: Process

  public static func binaryDirectory() -> URL? {
    if let dir = ProcessInfo.processInfo.environment["AGENTGATE_OPENCODE_DIR"] { return URL(fileURLWithPath: dir) }
    return Bundle.main.resourceURL?.appendingPathComponent("runtime/opencode")
  }

  /// The harness configuration: one local provider, and permissions that fail closed.
  static func config(
    engineURL: URL, engineKey: String, model: String, context: Int,
    capabilities: AgentCapabilities = AgentCapabilities(), folder: URL? = nil
  ) throws -> String {
    let budget = ContextBudget(context: context)
    let enabled = capabilities.enabledTools
    var config: [String: Any] = [
      "$schema": "https://opencode.ai/config.json",
      "autoupdate": false, "share": "disabled",
      "provider": ["local": [
        "npm": "@ai-sdk/openai-compatible", "name": "Local model",
        "options": ["baseURL": engineURL.appendingPathComponent("v1").absoluteString, "apiKey": engineKey],
        "models": [model: [
          "name": model, "tool_call": true, "limit": ["context": budget.context, "output": budget.reply],
        ]],
      ]],
      // Reads, globs, greps and lists ask too, so ToolCallCheck sees every call; the app answers
      // valid ones itself without bothering the user.
      "permission": permissions(capabilities),
      // A lean agent: the harness's general prompt and unused tools are about 11K tokens the model
      // would read before every first answer (27 s to the first word on a 4B model, 4.5 s without).
      "agent": [
        agentName: ["description": "Coding agent for the user's project", "mode": "primary", "prompt": prompt(capabilities)],
        // Plan mode: looks and designs, changes nothing. The user approves the plan before the build agent runs it.
        planAgentName: [
          "description": "Plans a change without making it", "mode": "primary", "prompt": planPrompt,
          "tools": ["edit": false, "write": false, "bash": false, "patch": false],
          "permission": ["edit": "deny", "bash": "deny"],
        ],
      ],
      "default_agent": agentName,
      "tools": Dictionary(uniqueKeysWithValues: optionalTools.filter { !enabled.contains($0) }.map { ($0, false) }),
      // Language servers only when code navigation is on; no formatters or per-step git snapshots.
      "lsp": capabilities.codeNavigation, "formatter": false, "snapshot": false,
    ]
    // The project's instructions file, named by the app: project config is off, so the harness would not find it.
    if let folder, FileManager.default.fileExists(atPath: folder.appendingPathComponent("AGENTS.md").path) {
      config["instructions"] = [folder.appendingPathComponent("AGENTS.md").path]
    }
    if capabilities.skills, let folder {
      // Only the project's own skills: the user's home folder and other assistants' skills stay out.
      config["skills"] = ["paths": [folder.appendingPathComponent(".agents/skills").path]]
    }
    let servers = capabilities.activeServers
    if !servers.isEmpty {
      config["mcp"] = Dictionary(uniqueKeysWithValues: servers.map {
        ($0.name, ["type": "local", "command": $0.command, "enabled": true] as [String: Any])
      })
    }
    // The harness's own compaction and tool-output cut-off, sized to this context (checked against OpenCode 1.19.5).
    config.merge(budget.harnessSettings) { _, new in new }
    return String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
  }

  static let agentName = "agentgate"
  static let planAgentName = "agentgate-plan"

  /// Harness tools that stay off unless a capability turns them on. "question" is always off: the app asks the
  /// user itself, on the step a question is about.
  static let optionalTools = ["task", "todowrite", "question", "skill", "webfetch", "websearch", "lsp"]

  /// Every call the gate must see asks first; the app answers safe ones itself. Off capabilities are denied, so
  /// a model that names a tool anyway is refused by the harness too.
  static func permissions(_ capabilities: AgentCapabilities) -> [String: String] {
    var permission = [
      "bash": "ask", "edit": "ask", "read": "ask", "glob": "ask", "grep": "ask", "list": "ask",
      "external_directory": "deny", "doom_loop": "ask",
      "webfetch": capabilities.webFetch ? "ask" : "deny",
      "websearch": capabilities.webSearch ? "ask" : "deny",
      "lsp": capabilities.codeNavigation ? "ask" : "deny",
    ]
    for server in capabilities.activeServers { permission["\(server.name)_*"] = "ask" }
    return permission
  }

  /// The system prompt with a line for each capability that is on, so the model knows when to use it.
  static func prompt(_ capabilities: AgentCapabilities) -> String {
    var lines = [agentPrompt]
    if capabilities.todos { lines.append("- For a task with three or more steps, keep a to-do list with todowrite and update it as you go.") }
    if capabilities.subagents { lines.append("- Hand a separate, well-defined part of a large task to a helper with the task tool.") }
    if capabilities.skills { lines.append("- When a skill matches the task, load it with the skill tool and follow it.") }
    if capabilities.codeNavigation { lines.append("- Use the lsp tool to find definitions and references instead of guessing.") }
    if capabilities.webFetch || capabilities.webSearch {
      lines.append("- Use the web only for documentation the project needs. Never send project code or secrets to the web.")
    }
    if !capabilities.activeServers.isEmpty { lines.append("- Tools named <server>_<tool> come from the user's MCP servers; use them when they fit.") }
    return lines.joined(separator: "\n")
  }

  /// The plan agent's prompt: read-only, ends with a numbered plan the user can approve.
  static let planPrompt = """
    You are planning a change in the user's project. Do not change anything: read, glob and grep only.
    Look at the files the task touches, then write a short numbered plan: which files change, what changes in each, \
    and how the change will be checked (the project's tests or build). Name risks and open questions.
    End with the line: PLAN READY
    """

  /// The agent's whole system prompt, in place of the harness's general one: short, because a local
  /// model reads it before every first answer.
  static let agentPrompt = """
    You are a coding agent working in the user's project folder on their Mac.
    Do the task with the tools you have: read, glob and grep to look, edit and write to change files, bash to run commands.
    - Look before you change: read the files you will edit.
    - Keep changes small and focused on the task. Match the project's existing style.
    - After a change, run the project's own build or tests when they exist, and fix what fails.
    - Stay inside the project folder. Never touch keys, credentials or files outside it.
    - If a tool call is refused, read the reason, correct the call and continue.
    - When the user names a file as @path, read that file first.
    - Be brief. When done, say in one or two sentences what you changed and how you checked it.
    """

  public static func start(
    folder: URL, engineURL: URL, engineKey: String, model: String, context: Int,
    capabilities: AgentCapabilities = AgentCapabilities(),
    binaries: URL? = binaryDirectory(), timeout: TimeInterval = 90
  ) async throws -> AgentServer {
    guard let exe = binaries?.appendingPathComponent("opencode"),
          FileManager.default.isExecutableFile(atPath: exe.path) else {
      throw AgentError.missingBinary(binaries?.path ?? "no runtime directory")
    }
    let port = try LlamaRuntime.freePort()
    let password = UUID().uuidString
    let home = AppPaths.support.appendingPathComponent("agent", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let process = Process()
    // Inside the macOS sandbox: the harness and every command it runs can write only the project, its own state
    // and temporary folders, and cannot read key folders. Fails closed: no sandbox, no harness.
    guard FileManager.default.isExecutableFile(atPath: AgentSandbox.executable) else {
      throw AgentError.missingBinary(AgentSandbox.executable)
    }
    process.executableURL = URL(fileURLWithPath: AgentSandbox.executable)
    process.arguments = ["-p", AgentSandbox.profile(writable: AgentSandbox.writable(project: folder, agentHome: home)),
                         exe.path, "serve", "--port", String(port), "--hostname", "127.0.0.1"]
    process.currentDirectoryURL = folder
    let inherited = ProcessInfo.processInfo.environment.filter { ["HOME", "TMPDIR", "LANG"].contains($0.key) }
    process.environment = inherited.merging([
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
      "XDG_STATE_HOME": home.appendingPathComponent("state").path,
      "XDG_DATA_HOME": home.appendingPathComponent("data").path,
      "XDG_CONFIG_HOME": home.appendingPathComponent("config").path,
      "XDG_CACHE_HOME": home.appendingPathComponent("cache").path,
      "OPENCODE_SERVER_PASSWORD": password,
      "OPENCODE_CONFIG_CONTENT": try config(
        engineURL: engineURL, engineKey: engineKey, model: model, context: context, capabilities: capabilities, folder: folder),
    ].merging(capabilities.environment) { $1 }) { $1 }
    let log = LogTail()
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty { handle.readabilityHandler = nil } else { log.append(data) }
    }
    try process.run()
    try? EngineRegistry().record(process.processIdentifier)
    let server = AgentServer(
      baseURL: URL(string: "http://127.0.0.1:\(port)")!, password: password, folder: folder,
      engineKey: engineKey, capabilities: capabilities, process: process, log: log)
    do {
      try await server.waitUntilReady(timeout: timeout)
    } catch {
      server.stop()
      throw error
    }
    return server
  }

  private let log: LogTail

  private init(
    baseURL: URL, password: String, folder: URL, engineKey: String, capabilities: AgentCapabilities, process: Process,
    log: LogTail
  ) {
    self.log = log
    self.capabilities = capabilities
    self.baseURL = baseURL
    self.password = password
    self.folder = folder
    self.engineKey = engineKey
    self.process = process
  }

  public var isRunning: Bool { process.isRunning }

  public var processIdentifier: Int32 { process.processIdentifier }

  public var client: AgentClient { AgentClient(baseURL: baseURL, password: password) }

  private func waitUntilReady(timeout: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      guard process.isRunning else { throw AgentError.startTimedOut(tail) }
      if (try? await client.sessionStatus()) != nil { return }
      try await Task.sleep(nanoseconds: 250_000_000)
    }
    throw AgentError.startTimedOut(tail)
  }

  /// The harness's last output, cleaned of keys and private paths, for error messages.
  private var tail: String {
    String(Redaction.clean(log.text, root: folder, label: "<project>").suffix(400))
  }

  public func stop() {
    let pid = process.processIdentifier
    if process.isRunning {
      process.terminate()
      for _ in 0..<50 where process.isRunning { usleep(100_000) }
      if process.isRunning { kill(pid, SIGKILL) }
    }
    EngineRegistry().forget(pid)
  }

  deinit { stop() }
}

/// Talks to the harness over HTTP. Every call carries the per-launch password.
public struct AgentClient: Sendable {
  let baseURL: URL
  let password: String

  private func request(_ method: String, _ path: String, body: [String: Any]? = nil) throws -> URLRequest {
    var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 30)
    request.httpMethod = method
    request.setValue("Basic " + Data("opencode:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    return request
  }

  @discardableResult
  private func send(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
    let (data, response) = try await URLSession.shared.data(for: request(method, path, body: body))
    guard let http = response as? HTTPURLResponse else { throw AgentError.malformed }
    guard (200..<300).contains(http.statusCode) else { throw AgentError.http(http.statusCode) }
    return data
  }

  func sessionStatus() async throws { try await send("GET", "session/status") }

  public func createSession(title: String) async throws -> String {
    struct Created: Decodable { var id: String }
    let data = try await send("POST", "session", body: ["title": title])
    guard let created = try? JSONDecoder().decode(Created.self, from: data) else { throw AgentError.malformed }
    return created.id
  }

  /// Sends a message. `plan` runs it with the plan agent, which may look but not change anything.
  public func prompt(session: String, text: String, model: String, plan: Bool = false) async throws {
    try await send("POST", "session/\(session)/prompt_async", body: [
      "model": ["providerID": "local", "modelID": model], "parts": [["type": "text", "text": text]],
      "agent": plan ? AgentServer.planAgentName : AgentServer.agentName,
    ])
  }

  /// Answers a permission request. A refusal with a `message` reaches the model as feedback it can
  /// correct the call from, instead of a bare "rejected".
  public func reply(permission: String, allow: Bool, message: String? = nil) async throws {
    var body: [String: Any] = ["reply": allow ? "once" : "reject"]
    if !allow, let message { body["message"] = message }
    try await send("POST", "permission/\(permission)/reply", body: body)
  }

  /// Questions the harness is waiting on, for any that arrived before the event stream was open.
  public func pendingPermissions() async throws -> [AgentEvent.Permission] {
    struct Pending: Decodable {
      struct Metadata: Decodable {
        var command: String?
        var path: String?
      }
      var id: String
      var permission: String
      var patterns: [String]?
      var metadata: Metadata?
      var tool: Lenient<CallRef>?
    }
    let data = try await send("GET", "permission")
    guard let items = try? JSONDecoder().decode([Pending].self, from: data) else { throw AgentError.malformed }
    return items.map {
      .init(
        id: $0.id, tool: $0.permission,
        detail: $0.metadata?.command ?? ($0.patterns ?? []).joined(separator: ", "), path: $0.metadata?.path,
        callID: $0.tool?.value?.callID)
    }
  }

  /// Sessions still working.
  public func busySessions() async throws -> Set<String> {
    let data = try await send("GET", "session/status")
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AgentError.malformed }
    return Set(object.keys)
  }

  public func abort(session: String) async throws { try await send("POST", "session/\(session)/abort") }

  /// The live event stream for every session of this server. Ends when the server stops or the task is cancelled.
  public func events() -> AsyncThrowingStream<AgentEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          var request = try request("GET", "event")
          request.timeoutInterval = 3600
          let (bytes, response) = try await URLSession.shared.bytes(for: request)
          guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AgentError.malformed }
          for try await line in bytes.lines where line.hasPrefix("data:") {
            if let event = AgentEventDecoder.decode(Data(line.dropFirst(5).utf8)) { continuation.yield(event) }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
