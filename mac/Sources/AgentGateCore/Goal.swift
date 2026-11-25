import Foundation

/// One long-running objective a session keeps working toward in rounds, such as "optimize this repository".
/// Each round is one agent turn. The app starts the next round when a turn ends, until the goal is complete,
/// blocked, paused, or out of rounds. Pure value type: every transition is unit-tested.
public struct Goal: Codable, Sendable, Equatable {
  public enum Phase: String, Codable, Sendable {
    /// Rounds keep starting while rounds remain.
    case active
    /// The user paused it, or stopped a round. Resume starts the next round.
    case paused
    /// It cannot go on without the user: the agent said so, it stalled, a round failed, or rounds ran out.
    case blocked
    /// The agent reported the objective met.
    case complete
  }

  /// What one finished round reported, read from the end of the agent's answer.
  public enum Report: Equatable, Sendable {
    case complete(String)
    case blocked(String)
    case progress(String?)
  }

  public static let defaultMaxRounds = 8
  public static let maxRoundsLimit = 50
  /// Rounds in a row that change no file before the goal counts as stalled.
  public static let stallLimit = 3

  public var objective: String
  public var maxRounds: Int
  public private(set) var roundsStarted = 0
  public private(set) var phase: Phase = .active
  /// Why it is blocked, in words for the user.
  public private(set) var blocker: String?
  /// The agent's own words: what it achieved when complete, or what the next round should do.
  public private(set) var note: String?
  public private(set) var stalledRounds = 0
  /// Files changed across all rounds, by successful edits.
  public private(set) var filesChanged = 0
  public let startedAt: Date

  public init(objective: String, maxRounds: Int = Goal.defaultMaxRounds, startedAt: Date = Date()) {
    self.objective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
    self.maxRounds = min(max(maxRounds, 1), Self.maxRoundsLimit)
    self.startedAt = startedAt
  }

  public var roundsLeft: Int { max(maxRounds - roundsStarted, 0) }
  public var canStartRound: Bool { phase == .active && roundsLeft > 0 }
  public var isFinished: Bool { phase == .complete || phase == .blocked }

  /// Starts the next round and returns the message the agent receives, or nil when no round may start.
  public mutating func startRound() -> String? {
    guard canStartRound else { return nil }
    roundsStarted += 1
    return prompt(round: roundsStarted)
  }

  /// Records how a round ended. `edits` is the number of files the round changed with successful edits.
  public mutating func finishRound(answer: String, edits: Int) {
    guard phase == .active else { return }
    filesChanged += edits
    switch Self.report(in: answer) {
    case .complete(let summary):
      phase = .complete
      note = summary
      blocker = nil
    case .blocked(let reason):
      block(reason.isEmpty ? "The agent needs your input to go on." : reason)
    case .progress(let next):
      note = next
      stalledRounds = edits > 0 ? 0 : stalledRounds + 1
      if stalledRounds >= Self.stallLimit {
        block("No file changed in \(Self.stallLimit) rounds in a row, so the goal stopped instead of repeating itself.")
      } else if roundsLeft == 0 {
        block("All \(maxRounds) rounds are used. Add rounds to keep going.")
      }
    }
  }

  /// A round could not finish: the engine or harness failed.
  public mutating func failRound(_ reason: String) {
    guard phase == .active else { return }
    block("A round failed: \(reason)")
  }

  public mutating func pause() {
    if phase == .active { phase = .paused }
  }

  /// Picks the goal up again, with `extraRounds` more when it ran out. False when nothing can resume it.
  @discardableResult
  public mutating func resume(extraRounds: Int = 0) -> Bool {
    guard phase != .complete else { return false }
    maxRounds = min(maxRounds + max(extraRounds, 0), Self.maxRoundsLimit)
    guard roundsLeft > 0 else { return false }
    phase = .active
    blocker = nil
    stalledRounds = 0
    return true
  }

  private mutating func block(_ reason: String) {
    phase = .blocked
    blocker = reason
  }

  /// The message for one round. The workspace is the authority, not what earlier rounds said, and the last
  /// line tells the app what happened, so any model that can follow an instruction can run a goal.
  public func prompt(round: Int) -> String {
    """
    Goal round \(round) of \(maxRounds). Objective: \(objective)

    Work toward the objective with your tools. Check the current files and tool results; they are the \
    authority, not earlier messages. Make one focused, verified improvement this round: change the code, then \
    run the project's tests or build to prove it still works.

    End your reply with exactly one of these lines:
    GOAL COMPLETE: <what was achieved>   (only when the whole objective is met and verified)
    GOAL BLOCKED: <why>   (when you cannot go on without the user)
    GOAL CONTINUE: <what the next round should do>
    """
  }

  /// The last marker line in an answer. No marker means the round made progress and says nothing more.
  public static func report(in answer: String) -> Report {
    for line in answer.split(whereSeparator: \.isNewline).reversed() {
      let text = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*_`>"))
      let upper = text.uppercased()
      for (marker, make) in [
        ("GOAL COMPLETE", Report.complete), ("GOAL BLOCKED", Report.blocked),
        ("GOAL CONTINUE", { Report.progress($0.isEmpty ? nil : $0) }),
      ] as [(String, (String) -> Report)] where upper.hasPrefix(marker) {
        let rest = text.dropFirst(marker.count).drop { $0 == ":" || $0 == " " || $0 == "*" }
        return make(String(rest).trimmingCharacters(in: .whitespaces))
      }
    }
    return .progress(nil)
  }

  /// The objective for "Optimize this repo", tied to the project's own check when one was found.
  public static func optimize(testCommand: String?) -> String {
    let check = testCommand.map { "Verify every change with `\($0)`." } ?? "Find the project's build or tests and verify every change with them."
    return "Optimize this repository. First make sure the build and tests pass. Then fix real bugs, simplify code "
      + "that is harder than it needs to be, and speed up slow paths. Keep each change small. \(check) "
      + "Do not change behaviour the tests rely on, and do not add dependencies."
  }
}
