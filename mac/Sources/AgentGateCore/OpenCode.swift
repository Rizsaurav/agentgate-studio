import Foundation

/// What the agent harness reports while it works, reduced to what the app shows.
public enum AgentEvent: Sendable, Equatable {
  /// A message exists and who wrote it ("user" or "assistant").
  case message(id: String, role: String)
  /// The full text of one text part so far.
  case text(partID: String, messageID: String, text: String)
  /// More text for an existing part.
  case textDelta(partID: String, messageID: String, delta: String)
  /// A tool call and where it stands: pending, running, completed or error.
  case tool(Tool)
  /// The harness wants the user's yes or no before running something.
  case permission(Permission)
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
    public var output: String
  }

  public struct Permission: Sendable, Equatable, Identifiable {
    public var id: String
    public var tool: String
    public var detail: String
    /// The folder a glob or grep searches in, when the call names one.
    public var path: String?

    public init(id: String, tool: String, detail: String, path: String? = nil) {
      self.id = id
      self.tool = tool
      self.detail = detail
      self.path = path
    }
  }
}

/// Decodes the harness's event stream. Unknown events are ignored, so a newer harness cannot break the app.
enum AgentEventDecoder {
  private struct Envelope: Decodable {
    struct Properties: Decodable {
      struct Part: Decodable {
        struct State: Decodable {
          struct Input: Decodable {
            var command: String?
            var filePath: String?
            var pattern: String?
          }
          var status: String?
          var input: Input?
          var output: String?
        }
        var id: String?
        var messageID: String?
        var type: String
        var text: String?
        var tool: String?
        var state: State?
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
      if part.type == "tool", let name = part.tool {
        let input = part.state?.input
        return .tool(.init(
          id: id, name: name, status: part.state?.status ?? "pending",
          detail: input?.command ?? input?.filePath ?? input?.pattern ?? "", output: part.state?.output ?? ""))
      }
      return nil
    case "message.part.delta":
      guard p.field == "text", let id = p.partID, let message = p.messageID, let delta = p.delta else { return nil }
      return .textDelta(partID: id, messageID: message, delta: delta)
    case "permission.asked":
      guard let id = p.id, let tool = p.permission else { return nil }
      let detail = p.metadata?.command ?? (p.patterns ?? []).joined(separator: ", ")
      return .permission(.init(id: id, tool: tool, detail: detail, path: p.metadata?.path))
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
  private let process: Process

  public static func binaryDirectory() -> URL? {
    if let dir = ProcessInfo.processInfo.environment["AGENTGATE_OPENCODE_DIR"] { return URL(fileURLWithPath: dir) }
    return Bundle.main.resourceURL?.appendingPathComponent("runtime/opencode")
  }

  /// The harness configuration: one local provider, and permissions that fail closed.
  static func config(engineURL: URL, engineKey: String, model: String, context: Int) throws -> String {
    let config: [String: Any] = [
      "$schema": "https://opencode.ai/config.json",
      "autoupdate": false, "share": "disabled",
      "provider": ["local": [
        "npm": "@ai-sdk/openai-compatible", "name": "Local model",
        "options": ["baseURL": engineURL.appendingPathComponent("v1").absoluteString, "apiKey": engineKey],
        "models": [model: ["name": model, "tool_call": true, "limit": ["context": context, "output": 4096]]],
      ]],
      // Reads, globs, greps and lists ask too, so ToolCallCheck sees every call; the app answers
      // valid ones itself without bothering the user.
      "permission": [
        "bash": "ask", "edit": "ask", "read": "ask", "glob": "ask", "grep": "ask", "list": "ask",
        "webfetch": "deny", "external_directory": "deny",
      ],
    ]
    return String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
  }

  public static func start(
    folder: URL, engineURL: URL, engineKey: String, model: String, context: Int,
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
      "OPENCODE_CONFIG_CONTENT": try config(engineURL: engineURL, engineKey: engineKey, model: model, context: context),
    ]) { $1 }
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
      engineKey: engineKey, process: process, log: log)
    do {
      try await server.waitUntilReady(timeout: timeout)
    } catch {
      server.stop()
      throw error
    }
    return server
  }

  private let log: LogTail

  private init(baseURL: URL, password: String, folder: URL, engineKey: String, process: Process, log: LogTail) {
    self.log = log
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

  public func prompt(session: String, text: String, model: String) async throws {
    try await send("POST", "session/\(session)/prompt_async", body: [
      "model": ["providerID": "local", "modelID": model], "parts": [["type": "text", "text": text]],
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
    }
    let data = try await send("GET", "permission")
    guard let items = try? JSONDecoder().decode([Pending].self, from: data) else { throw AgentError.malformed }
    return items.map {
      .init(
        id: $0.id, tool: $0.permission,
        detail: $0.metadata?.command ?? ($0.patterns ?? []).joined(separator: ", "), path: $0.metadata?.path)
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
