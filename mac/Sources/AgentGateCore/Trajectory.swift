import Foundation

/// One harness task from `evals/trajectory/tasks/<id>/` (#118): a small project and what must be true after.
/// Scored on outcomes (files, test results, nothing outside the project), never on the wording of an answer
/// alone: a task with a pre-existing failure elsewhere is not marked wrong for it, only its own goal counts.
public struct TrajectoryTask: Codable, Sendable, Equatable, Identifiable {
  public enum Check: Codable, Sendable, Equatable {
    /// A shell command run in the project afterwards must exit 0 (tests, a build, an assertion).
    case command(String)
    case fileContains(path: String, text: String)
    case fileUnchanged(String)
    /// No file of this name may appear in the folder above the project.
    case noFileOutside(String)
    /// No file ending in `suffix` may contain `text`.
    case noTextInFiles(suffix: String, text: String)
    /// Only for questions: the answer must name this. Used where the outcome is an answer, not a file.
    case answerContains(String)

    private enum Key: String, CodingKey { case command, fileContains, fileUnchanged, noFileOutside, noTextInFiles, answerContains }
    private struct PathText: Codable { var path: String; var text: String }
    private struct SuffixText: Codable { var suffix: String; var text: String }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: Key.self)
      guard c.allKeys.count == 1, let key = c.allKeys.first else {
        throw TrajectoryError.invalid("a check must have exactly one kind")
      }
      switch key {
      case .command: self = .command(try c.decode(String.self, forKey: key))
      case .fileContains: let v = try c.decode(PathText.self, forKey: key); self = .fileContains(path: v.path, text: v.text)
      case .fileUnchanged: self = .fileUnchanged(try c.decode(String.self, forKey: key))
      case .noFileOutside: self = .noFileOutside(try c.decode(String.self, forKey: key))
      case .noTextInFiles: let v = try c.decode(SuffixText.self, forKey: key); self = .noTextInFiles(suffix: v.suffix, text: v.text)
      case .answerContains: self = .answerContains(try c.decode(String.self, forKey: key))
      }
    }

    public func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: Key.self)
      switch self {
      case .command(let v): try c.encode(v, forKey: .command)
      case .fileContains(let path, let text): try c.encode(PathText(path: path, text: text), forKey: .fileContains)
      case .fileUnchanged(let v): try c.encode(v, forKey: .fileUnchanged)
      case .noFileOutside(let v): try c.encode(v, forKey: .noFileOutside)
      case .noTextInFiles(let suffix, let text): try c.encode(SuffixText(suffix: suffix, text: text), forKey: .noTextInFiles)
      case .answerContains(let v): try c.encode(v, forKey: .answerContains)
      }
    }
  }

  public var id: String
  /// read, search, fix-test, feature, refuse, recover, multi-file.
  public var kind: String
  public var prompt: String
  public var maxSeconds: Int
  public var checks: [Check]

  public static let kinds = ["read", "search", "fix-test", "feature", "refuse", "recover", "multi-file"]

  /// Every task under `folder/tasks`, each with its project, validated as a whole.
  public static func loadAll(from folder: URL) throws -> [(task: TrajectoryTask, project: URL)] {
    let tasks = folder.appendingPathComponent("tasks")
    let ids = try FileManager.default.contentsOfDirectory(atPath: tasks.path).filter { !$0.hasPrefix(".") }.sorted()
    var all: [(TrajectoryTask, URL)] = []
    for id in ids {
      let dir = tasks.appendingPathComponent(id)
      let task: TrajectoryTask
      do { task = try JSONDecoder().decode(TrajectoryTask.self, from: Data(contentsOf: dir.appendingPathComponent("task.json"))) }
      catch { throw TrajectoryError.invalid("\(id)/task.json could not be read (\(error))") }
      guard task.id == id, kinds.contains(task.kind), !task.prompt.isEmpty, !task.checks.isEmpty, (30...3600).contains(task.maxSeconds) else {
        throw TrajectoryError.invalid("\(id) has a bad id, kind, prompt, checks or time limit")
      }
      for check in task.checks {
        if case .fileContains(let path, _) = check, path.contains("..") || path.hasPrefix("/") { throw TrajectoryError.invalid("\(id) checks a path outside its project") }
        if case .fileUnchanged(let path) = check, path.contains("..") || path.hasPrefix("/") { throw TrajectoryError.invalid("\(id) checks a path outside its project") }
      }
      guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("project").path) else { throw TrajectoryError.invalid("\(id) has no project folder") }
      all.append((task, dir.appendingPathComponent("project")))
    }
    for kind in kinds where !all.contains(where: { $0.0.kind == kind }) { throw TrajectoryError.invalid("no task of kind \(kind)") }
    return all
  }
}

public enum TrajectoryError: Error, Equatable, CustomStringConvertible {
  case invalid(String)
  case setup(String)

  public var description: String {
    switch self {
    case .invalid(let why): "The trajectory suite is invalid: \(why)."
    case .setup(let why): "A task could not be set up: \(why)."
    }
  }
}

/// What the harness did on one task: the trajectory, and whether the outcome was right.
public struct TrajectoryRecord: Codable, Sendable, Equatable {
  public struct Step: Codable, Sendable, Equatable {
    public var tool: String
    /// The command or path, relative to the project.
    public var detail: String
    /// completed, error, or refused: <rule>.
    public var status: String
  }

  public var task: String
  public var passed: Bool
  /// Why it failed, in one line; empty when it passed.
  public var reason: String
  public var seconds: Double
  public var steps: [Step]
  /// Calls that would have asked the user (edits, commands); here answered by the app's own rules.
  public var approvalsAsked: Int
  /// Calls the app's rules refused.
  public var refused: Int
  /// Shell commands that ran tests.
  public var testsRun: [String]
  /// From git in the task's copy: "M calc.py", "?? NEW.md".
  public var filesChanged: [String]
  public var inputTokens: Int?
  public var outputTokens: Int?
}

/// Scores a finished task in its copy. Runs nothing the task did not name.
public enum TrajectoryScorer {
  public static func check(_ task: TrajectoryTask, folder: URL, original: URL, answer: String) -> String? {
    for check in task.checks {
      switch check {
      case .command(let command):
        let (code, output) = run(command, in: folder)
        if code != 0 { return "`\(command)` failed (exit \(code)): \(output.suffix(160))" }
      case .fileContains(let path, let text):
        guard let body = try? String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8) else { return "\(path) is missing" }
        if !body.contains(text) { return "\(path) does not contain \"\(text)\"" }
      case .fileUnchanged(let path):
        let now = try? Data(contentsOf: folder.appendingPathComponent(path))
        let before = try? Data(contentsOf: original.appendingPathComponent(path))
        if now != before { return "\(path) was changed, but must not be" }
      case .noFileOutside(let name):
        if FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().appendingPathComponent(name).path) {
          return "\(name) was written outside the project"
        }
      case .noTextInFiles(let suffix, let text):
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for file in files where file.pathExtension.isEmpty == false && file.lastPathComponent.hasSuffix(suffix) && !file.path.contains("/.git/") {
          if let body = try? String(contentsOf: file, encoding: .utf8), body.contains(text) {
            return "\(file.lastPathComponent) still contains \"\(text)\""
          }
        }
      case .answerContains(let text):
        if !answer.localizedCaseInsensitiveContains(text) {
          // What it did say, so a scoring mistake can be told from a wrong answer.
          let said = answer.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(100)
          return "the answer does not mention \"\(text)\" (it said: \(said.isEmpty ? "nothing" : "\"\(said)\""))"
        }
      }
    }
    return nil
  }

  /// Runs a check command in the copy with a time limit; never in the real project.
  static func run(_ command: String, in folder: URL, timeout: TimeInterval = 120) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.currentDirectoryURL = folder
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin", "HOME": folder.path,
                           "PYTHONDONTWRITEBYTECODE": "1"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    let output = LockedOutput()
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty { handle.readabilityHandler = nil } else { output.append(data) }
    }
    do { try process.run() } catch { return (127, "could not start: \(error)") }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline { usleep(20_000) }
    if process.isRunning { process.terminate(); return (124, "timed out after \(Int(timeout)) s") }
    pipe.fileHandleForReading.readabilityHandler = nil
    output.append(pipe.fileHandleForReading.readDataToEndOfFile())
    return (process.terminationStatus, output.text)
  }
}

private final class LockedOutput: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()
  func append(_ chunk: Data) { lock.withLock { data.append(chunk.prefix(64 << 10)) } }
  var text: String { lock.withLock { String(decoding: data.suffix(4096), as: UTF8.self) } }
}

/// Runs tasks with the real harness through the gateway, in a fresh copy of each task's project.
/// Calls are answered by the app's own rules, as a session would without a person: reads and edits that
/// pass the call check run, commands run unless a rule blocks them, everything else is refused.
public struct TrajectoryRunner: Sendable {
  public var gateway: Gateway
  public var model: String
  public var context: Int
  public var harness: URL?

  public init(gateway: Gateway, model: String, context: Int, harness: URL? = AgentServer.binaryDirectory()) {
    self.gateway = gateway
    self.model = model
    self.context = context
    self.harness = harness
  }

  public func run(_ task: TrajectoryTask, project: URL) async throws -> TrajectoryRecord {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent("agentgate-trajectory-\(UUID().uuidString)", isDirectory: true)
    let folder = parent.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    try FileManager.default.copyItem(at: project, to: folder)
    // A baseline commit, so `git status` afterwards says exactly what the agent changed.
    for args in [["init", "-q"], ["add", "-A"], ["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "start"]] {
      let (code, output) = TrajectoryScorer.run("git " + args.map { "'\($0)'" }.joined(separator: " "), in: folder)
      guard code == 0 else { throw TrajectoryError.setup("git \(args[0]) failed: \(output)") }
    }

    let start = Date()
    let server = try await AgentServer.start(
      folder: folder, engineURL: gateway.baseURL, engineKey: gateway.key, model: model, context: context, binaries: harness)
    defer { server.stop() }
    let client = server.client
    let session = try await client.createSession(title: task.id)
    let events = Task { () throws -> (answer: String, steps: [TrajectoryRecord.Step], asked: Int, refused: Int) in
      var parts: [String: String] = [:]
      var order: [String] = []
      var roles: [String: String] = [:]
      var messageOf: [String: String] = [:]
      var steps: [String: TrajectoryRecord.Step] = [:]
      var stepOrder: [String] = []
      var asked = 0
      var refused = 0
      for try await event in client.events() {
        switch event {
        case .message(let id, let role): roles[id] = role
        case .text(let id, let message, let text):
          if parts[id] == nil { order.append(id) }
          parts[id] = text
          messageOf[id] = message
        case .textDelta(let id, let message, let delta):
          if parts[id] == nil { order.append(id) }
          parts[id, default: ""] += delta
          messageOf[id] = message
        case .tool(let tool):
          if steps[tool.id] == nil { stepOrder.append(tool.id) }
          steps[tool.id] = .init(tool: tool.name, detail: Redaction.clean(tool.detail, root: folder, label: "<project>"), status: tool.status)
        case .permission(let permission):
          let allow = Self.allowed(permission, folder: folder)
          if !ToolCallCheck.readOnly.contains(permission.tool) { asked += 1 }
          if !allow { refused += 1 }
          try await client.reply(permission: permission.id, allow: allow,
                                 message: allow ? nil : "Refused by AGENTGATE. Stay inside the project and use another way.")
        case .idle:
          let answer = order.filter { roles[messageOf[$0] ?? ""] == "assistant" }.compactMap { parts[$0] }.joined(separator: "\n\n")
          return (answer, stepOrder.compactMap { steps[$0] }, asked, refused)
        case .failed(let message): throw TrajectoryError.setup("the harness stopped: \(message)")
        default: break
        }
      }
      return ("", stepOrder.compactMap { steps[$0] }, asked, refused)
    }
    let limit = task.maxSeconds
    let timer = Task { try await Task.sleep(for: .seconds(limit)); events.cancel() }
    try await Task.sleep(nanoseconds: 500_000_000)
    try await client.prompt(session: session, text: task.prompt, model: model)
    let outcome: (answer: String, steps: [TrajectoryRecord.Step], asked: Int, refused: Int)
    var timedOut = false
    do {
      outcome = try await events.value
    } catch is CancellationError {
      timedOut = true
      outcome = ("", [], 0, 0)
      try? await client.abort(session: session)
    }
    timer.cancel()
    let seconds = (Date().timeIntervalSince(start) * 10).rounded() / 10

    let reason = timedOut ? "did not finish within \(limit) s" : TrajectoryScorer.check(task, folder: folder, original: project, answer: outcome.answer)
    let (_, status) = TrajectoryScorer.run("git status --porcelain --untracked-files=all", in: folder)
    // Token counts are a report, not a score: a harness that cannot give them leaves them empty ("not reported").
    let tokens = try? await client.tokens(session: session)
    return TrajectoryRecord(
      task: task.id, passed: reason == nil, reason: reason ?? "", seconds: seconds, steps: outcome.steps,
      approvalsAsked: outcome.asked, refused: outcome.refused,
      testsRun: outcome.steps.filter { $0.tool == "bash" && ($0.detail.contains("test") || $0.detail.contains("pytest")) }.map(\.detail),
      filesChanged: status.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.sorted(),
      inputTokens: tokens?.input, outputTokens: tokens?.output)
  }

  /// The app's rules, without a person: the call check first, then the policy for commands and edits.
  static func allowed(_ permission: AgentEvent.Permission, folder: URL) -> Bool {
    if ToolCallCheck.check(permission, folder: folder) != nil { return false }
    if ToolCallCheck.readOnly.contains(permission.tool) { return true }
    switch permission.tool {
    case "bash":
      if case .block = ToolPolicy.evaluate(tool: "bash", detail: permission.detail, folder: folder) { return false }
      return true
    case "edit", "write", "patch", "multiedit":
      return true
    default:
      return false
    }
  }
}
