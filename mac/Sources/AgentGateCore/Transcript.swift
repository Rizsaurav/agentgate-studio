import Foundation

/// One entry of the agent's turn, in the order it happened: some answer text, the model's reasoning,
/// a tool call with what it printed, or a call the app refused.
public struct AgentStep: Codable, Sendable, Equatable, Identifiable {
  public enum Kind: String, Codable, Sendable { case text, reasoning, tool, refused }
  public enum Status: String, Codable, Sendable { case pending, running, done, failed, refused }

  public var id: String
  public var kind: Kind
  /// The tool's name; empty for text and reasoning.
  public var tool: String
  /// The text for text and reasoning; the command, path or pattern for a tool.
  public var text: String
  public var title: String?
  /// The model's own words for what a command is for.
  public var purpose: String?
  /// What the tool printed (so far, while it runs), or why it was refused. The tail is kept when long.
  public var output: String
  public var diff: String?
  public var exitCode: Int?
  public var error: String?
  public var status: Status
  public var started: Date?
  public var ended: Date?
  /// Earlier output was cut, by the harness or to keep the transcript small.
  public var truncated: Bool
  /// The agent's to-do list, for a todowrite step.
  public var todos: [TodoItem]?

  public init(
    id: String, kind: Kind, tool: String = "", text: String, title: String? = nil, purpose: String? = nil,
    output: String = "", diff: String? = nil, exitCode: Int? = nil, error: String? = nil, status: Status,
    started: Date? = nil, ended: Date? = nil, truncated: Bool = false, todos: [TodoItem]? = nil
  ) {
    self.todos = todos
    self.id = id
    self.kind = kind
    self.tool = tool
    self.text = text
    self.title = title
    self.purpose = purpose
    self.output = output
    self.diff = diff
    self.exitCode = exitCode
    self.error = error
    self.status = status
    self.started = started
    self.ended = ended
    self.truncated = truncated
  }

  /// The reason a step carries when the user pressed Deny, so the chat can say so instead of "blocked".
  public static let deniedByUser = "You chose Deny. The agent was told to take another way."

  public var duration: TimeInterval? {
    guard let started, let ended else { return nil }
    return ended.timeIntervalSince(started)
  }

  /// Lines added and removed by an edit, from its diff.
  public var diffCounts: (added: Int, removed: Int)? {
    guard let diff else { return nil }
    var added = 0
    var removed = 0
    for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
      if line.hasPrefix("+") { added += 1 } else if line.hasPrefix("-") { removed += 1 }
    }
    return (added, removed)
  }
}

/// One entry of the agent's to-do list.
public struct TodoItem: Codable, Sendable, Equatable {
  public var content: String
  /// pending, in_progress, completed or cancelled.
  public var status: String

  public init(content: String, status: String) {
    self.content = content
    self.status = status
  }

  private enum CodingKeys: String, CodingKey { case content, status }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    content = try c.decode(String.self, forKey: .content)
    status = try c.decodeIfPresent(String.self, forKey: .status) ?? "pending"
  }

  public var isDone: Bool { status == "completed" }
}

/// What one turn used, for the line under the answer.
public struct TurnUsage: Codable, Sendable, Equatable {
  public var tokensIn: Int
  public var tokensOut: Int
  public var seconds: TimeInterval

  public init(tokensIn: Int = 0, tokensOut: Int = 0, seconds: TimeInterval = 0) {
    self.tokensIn = tokensIn
    self.tokensOut = tokensOut
    self.seconds = seconds
  }
}

/// Builds the visible transcript of one turn from the harness's events. The user's own message, which
/// the harness echoes back, is left out.
public struct Transcript: Sendable, Equatable {
  /// Characters of output kept per step: the tail, which is where a command's result and errors are.
  public static let outputLimit = 20_000

  private var all: [AgentStep] = []
  private var messageOf: [String: String] = [:]
  private var roles: [String: String] = [:]
  /// The harness's call id → the step showing that call.
  private var stepOfCall: [String: String] = [:]
  /// A call the app refused: call id → the refusal step that stands for it.
  private var refusalOfCall: [String: String] = [:]
  /// When the user approved a call (by call id), which is when it really started running.
  private var approvedAt: [String: Date] = [:]
  public private(set) var usage = TurnUsage()

  public init() {}

  /// Every step a user should see, in order.
  public var steps: [AgentStep] {
    all.filter { step in
      guard step.kind == .text || step.kind == .reasoning else { return true }
      return messageOf[step.id].flatMap { roles[$0] } == "assistant"
    }
  }

  /// The answer: the assistant's text parts.
  public var answer: String {
    steps.filter { $0.kind == .text }.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
  }

  /// The step in progress: a running tool, else one about to start. A model can queue the next call
  /// while a command still runs; the running command is what the user is waiting on.
  public var running: AgentStep? {
    let tools = steps.filter { $0.kind == .tool }
    return tools.last { $0.status == .running } ?? tools.last { $0.status == .pending }
  }

  /// Applies one event. `clean` redacts what a tool printed (keys, private paths) before it is kept.
  public mutating func apply(_ event: AgentEvent, clean: (String) -> String = { $0 }) {
    switch event {
    case .message(let id, let role):
      roles[id] = role
    case .text(let id, let message, let text):
      upsertText(id: id, message: message, kind: .text) { $0 = text }
    case .reasoning(let id, let message, let text):
      upsertText(id: id, message: message, kind: .reasoning) { $0 = text }
    case .textDelta(let id, let message, let delta):
      // A delta belongs to whichever part it names, answer or reasoning.
      let kind = all.first { $0.id == id }?.kind ?? .text
      upsertText(id: id, message: message, kind: kind) { $0 += delta }
    case .tool(let tool):
      apply(tool, clean: clean)
    case .usage(_, let reported):
      // Each model call reports the whole context it read, so the largest is the turn's input size.
      guard let reported else { break }
      usage.tokensIn = max(usage.tokensIn, reported.prompt)
      usage.tokensOut += reported.generated
    case .permission, .permissionReplied, .compacted, .busy, .idle, .connected, .failed:
      break
    }
  }

  /// A call the app refused before it ran, with the reason shown to the user. When the question named
  /// its call, that call's step becomes the refusal, so the user sees one card for one call.
  public mutating func refuse(
    id: String, tool: String, detail: String, reason: String, callID: String?, at date: Date = Date()
  ) {
    var step = AgentStep(
      id: id, kind: .refused, tool: tool, text: detail, output: reason, status: .refused, started: date, ended: date)
    if let callID {
      refusalOfCall[callID] = id
      if let stepID = stepOfCall[callID], let index = all.firstIndex(where: { $0.id == stepID }) {
        // The harness knows the readable command or path better than the question did.
        if !all[index].text.isEmpty { step.text = all[index].text }
        all[index] = step
        return
      }
    }
    if let index = all.firstIndex(where: { $0.id == id }) { all[index] = step } else { all.append(step) }
  }

  /// The user approved this call: its clock starts now, not when the model asked.
  public mutating func approved(callID: String?, at date: Date = Date()) {
    guard let callID else { return }
    approvedAt[callID] = date
    if let stepID = stepOfCall[callID], let index = all.firstIndex(where: { $0.id == stepID }) {
      all[index].started = date
    }
  }

  /// The step a question is about, while it waits: nil when the question named no call, or the
  /// call's step has not appeared yet.
  public func waitingStep(callID: String?) -> String? {
    guard let callID, let stepID = stepOfCall[callID],
          let step = all.first(where: { $0.id == stepID }), step.kind == .tool,
          step.status == .pending || step.status == .running else { return nil }
    return stepID
  }

  public mutating func finish(seconds: TimeInterval) {
    usage.seconds = seconds
    // Anything still running stopped with the turn.
    for index in all.indices where all[index].kind == .tool && (all[index].status == .running || all[index].status == .pending) {
      all[index].status = .failed
      if all[index].error == nil { all[index].error = "Stopped when the turn ended." }
    }
  }

  private mutating func upsertText(id: String, message: String, kind: AgentStep.Kind, change: (inout String) -> Void) {
    messageOf[id] = message
    if let index = all.firstIndex(where: { $0.id == id }) {
      change(&all[index].text)
    } else {
      var text = ""
      change(&text)
      all.append(AgentStep(id: id, kind: kind, text: text, status: .done))
    }
  }

  private mutating func apply(_ tool: AgentEvent.Tool, clean: (String) -> String) {
    var status: AgentStep.Status = switch tool.status {
    case "running": .running
    case "completed": .done
    case "error": .failed
    default: .pending
    }
    if status == .done, let code = tool.exitCode, code != 0 { status = .failed }
    // The harness refused the call under its own rules: it never ran.
    if status == .failed, (tool.error ?? "").contains("prevents you from using this specific tool call") { status = .refused }
    if let callID = tool.callID {
      // A refused call stays the refusal; later updates (the harness's "rejected") only sharpen its text.
      if let refusalID = refusalOfCall[callID] {
        if let index = all.firstIndex(where: { $0.id == refusalID }), !tool.detail.isEmpty {
          all[index].text = clean(tool.detail)
        }
        return
      }
      stepOfCall[callID] = tool.id
    }
    let (output, cut) = Self.kept(tool.output, clean: clean)
    let step = AgentStep(
      id: tool.id, kind: .tool, tool: tool.name, text: clean(tool.detail), title: tool.title.map(clean),
      purpose: tool.purpose, output: output, diff: tool.diff.map { Self.kept($0, clean: clean).text },
      exitCode: tool.exitCode, error: tool.error.map(clean), status: status,
      started: tool.callID.flatMap { approvedAt[$0] } ?? tool.started,
      ended: tool.ended, truncated: tool.truncated || cut, todos: tool.todos)
    if let index = all.firstIndex(where: { $0.id == tool.id }) {
      // Updates carry the whole state; keep what an earlier update knew and this one leaves out.
      var merged = step
      let old = all[index]
      if merged.text.isEmpty { merged.text = old.text }
      if merged.output.isEmpty { merged.output = old.output }
      merged.started = merged.started ?? old.started
      all[index] = merged
    } else {
      all.append(step)
    }
  }

  /// The tail of long output, cleaned. Cut first so a huge output costs no more than its tail on every
  /// update; the margin keeps a key that straddles the cut long enough to be recognised and hidden.
  static func kept(_ raw: String, clean: (String) -> String) -> (text: String, cut: Bool) {
    guard raw.utf8.count > outputLimit, raw.count > outputLimit else { return (clean(raw), false) }
    let cleaned = clean(String(raw.suffix(outputLimit + 512)))
    return ("…\n" + String(cleaned.suffix(outputLimit)), true)
  }
}
