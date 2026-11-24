import Foundation

/// How a model's context window is split for agent sessions, from the size the planner chose for this Mac.
/// The user never picks a size: the budget follows the context.
public struct ContextBudget: Sendable, Equatable {
  public let context: Int
  /// Room kept for the model's reply.
  public let reply: Int
  /// Kept free so compaction itself never overflows the window.
  public let reserved: Int
  /// Recent turns kept word for word when older ones are summarised.
  public let preserveRecent: Int
  /// Tool output above these limits is cut to a preview; the full text is saved and can be read in parts.
  public let toolLines: Int
  public let toolBytes: Int

  /// What is left for the conversation itself.
  public var history: Int { context - reply - reserved }

  public init(context: Int) {
    let size = max(context, 4096)
    self.context = size
    reply = size / 8
    reserved = size / 8
    preserveRecent = size / 4
    // About a quarter of the window for one tool result, at roughly 4 bytes per token.
    toolBytes = size
    toolLines = max(100, size / 40)
  }

  /// The harness settings that carry this budget: its own compaction, configured rather than rewritten.
  public var harnessSettings: [String: Any] {
    [
      "compaction": ["auto": true, "prune": true, "preserve_recent_tokens": preserveRecent, "reserved": reserved],
      "tool_output": ["max_lines": toolLines, "max_bytes": toolBytes],
    ]
  }
}

/// How full the context was on the last model call, for the session's one-line indicator.
public struct ContextMeter: Sendable, Equatable {
  public let used: Int
  public let context: Int

  public init(used: Int, context: Int) {
    self.used = max(0, used)
    self.context = max(1, context)
  }

  public var fraction: Double { min(1, Double(used) / Double(context)) }
  public var percent: Int { Int((fraction * 100).rounded()) }

  public var label: String { "Context \(percent)% of \(context / 1024)K" }

  /// Near the point where older turns are summarised.
  public var isNearlyFull: Bool { fraction >= 0.8 }
}

/// What must survive compaction word for word: the user's task and the decisions made along the way.
/// After the harness summarises older turns, this is sent again with the next message.
public struct PinnedContext: Sendable, Equatable {
  public static let maxDecisions = 12
  public static let maxDecisionLength = 300
  public static let maxTaskLength = 2000

  public private(set) var task: String
  public private(set) var decisions: [String]

  public init(task: String, decisions: [String] = []) {
    self.task = String(task.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxTaskLength))
    self.decisions = []
    for decision in decisions { add(decision) }
  }

  /// The task is the session's first user message; decisions are lines the user starts with "Decision:" or
  /// "Decided:". Nothing the model or a tool wrote is pinned, so a tool cannot plant an instruction here.
  public static func from(userMessages: [String]) -> PinnedContext? {
    guard let first = userMessages.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
      return nil
    }
    var pinned = PinnedContext(task: first)
    for message in userMessages {
      for line in message.split(separator: "\n") {
        let text = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["decision:", "decided:"] where text.lowercased().hasPrefix(prefix) {
          pinned.add(String(text.dropFirst(prefix.count)))
        }
      }
    }
    return pinned
  }

  mutating func add(_ decision: String) {
    let text = String(decision.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxDecisionLength))
    guard !text.isEmpty, !decisions.contains(text) else { return }
    decisions.append(text)
    // The newest decisions matter most; the oldest go first.
    if decisions.count > Self.maxDecisions { decisions.removeFirst(decisions.count - Self.maxDecisions) }
  }

  /// The block sent ahead of the next message after a compaction.
  public func preamble() -> String {
    var lines = ["Older turns of this session were summarised to fit the context. Kept word for word:", "Task: \(task)"]
    if !decisions.isEmpty { lines += ["Decisions:"] + decisions.map { "- \($0)" } }
    return lines.joined(separator: "\n")
  }

  /// Rough tokens, at 4 characters each, so the block can be checked against the budget.
  public var tokens: Int { preamble().count / 4 + 1 }
}
