import Foundation
import Testing

@testable import AgentGateCore

/// A stand-in for the harness's compaction, close to what OpenCode does: when the history no longer fits, older
/// turns become one lossy summary and the most recent `preserveRecent` tokens stay word for word.
private struct CompactingHarness {
  struct Turn { var text: String; var tokens: Int { text.count / 4 + 1 } }
  let budget: ContextBudget
  var turns: [Turn] = []
  var summary: String?
  var compactions = 0

  init(budget: ContextBudget) { self.budget = budget }

  var historyTokens: Int { turns.reduce(0) { $0 + $1.tokens } + (summary.map { $0.count / 4 + 1 } ?? 0) }

  /// What the model reads on the next call.
  var visible: String { ([summary].compactMap { $0 } + turns.map(\.text)).joined(separator: "\n") }

  /// Adds a turn; returns true when this made the harness compact.
  mutating func add(_ text: String) -> Bool {
    turns.append(Turn(text: text))
    guard historyTokens > budget.history else { return false }
    var kept: [Turn] = []
    var keptTokens = 0
    for turn in turns.reversed() {
      guard keptTokens + turn.tokens <= budget.preserveRecent else { break }
      kept.insert(turn, at: 0)
      keptTokens += turn.tokens
    }
    // Lossy on purpose: a summary keeps the gist, not the exact task or decisions.
    summary = "[Summary of \(turns.count - kept.count) earlier turns: the user and the agent worked on the code.]"
    turns = kept
    compactions += 1
    return true
  }
}

@Suite struct ContextBudgetTests {
  @Test(arguments: [8192, 16384, 32768])
  func theBudgetSplitsTheWindowAndLeavesRoomForHistory(context: Int) {
    let budget = ContextBudget(context: context)
    #expect(budget.reply + budget.reserved + budget.history == context)
    #expect(budget.history >= context * 3 / 4)
    #expect(budget.preserveRecent < budget.history)
    #expect(budget.toolBytes / 4 <= context / 4)
  }

  @Test func theHarnessIsConfiguredWithItsOwnCompactionAndCutOffs() throws {
    let text = try AgentServer.config(engineURL: URL(string: "http://127.0.0.1:1")!, engineKey: "k", model: "m", context: 8192)
    let json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    let compaction = try #require(json["compaction"] as? [String: Any])
    #expect(compaction["auto"] as? Bool == true && compaction["prune"] as? Bool == true)
    #expect(compaction["preserve_recent_tokens"] as? Int == 2048 && compaction["reserved"] as? Int == 1024)
    let tool = try #require(json["tool_output"] as? [String: Int])
    #expect(tool["max_bytes"] == 8192 && tool["max_lines"] == 204)
    let provider = try #require((json["provider"] as? [String: Any])?["local"] as? [String: Any])
    let limit = ((provider["models"] as? [String: Any])?["m"] as? [String: Any])?["limit"] as? [String: Int]
    #expect(limit == ["context": 8192, "output": 1024])
  }

  @Test(arguments: [8192, 16384, 32768])
  func aLongSessionKeepsItsTaskAndDecisionsThroughCompaction(context: Int) {
    let budget = ContextBudget(context: context)
    var harness = CompactingHarness(budget: budget)
    let task = "Add retry with backoff to the uploader in Sources/Upload.swift and keep the public API unchanged."
    var userMessages = [task]
    _ = harness.add(task)
    var compactedAt: [Int] = []
    var totalText = task.count
    // Enough steps that the whole session is several times the window.
    let steps = context / 100
    for step in 1...steps {
      // Every tenth user message records a decision; tools return long output in between.
      var user = "Step \(step): continue."
      if step % 10 == 0 { user += "\nDecision: use exponential backoff capped at \(step) seconds" }
      userMessages.append(user)
      let tool = "Tool output for step \(step):\n" + String(repeating: "log line \(step)\n", count: 40)
      totalText += user.count + tool.count
      var compacted = harness.add(user)
      compacted = harness.add(tool) || compacted
      if compacted { compactedAt.append(step) }
      if compacted {
        // The app answers a compaction by sending the pinned task and decisions with the next message.
        let pinned = PinnedContext.from(userMessages: userMessages)!
        _ = harness.add(pinned.preamble())
        #expect(harness.visible.contains(task), "task lost at \(context) after step \(step)")
        for decision in pinned.decisions { #expect(harness.visible.contains(decision)) }
        #expect(harness.historyTokens <= budget.history)
      }
    }
    // The session needed more text than the window holds, so compaction really happened.
    #expect(totalText / 4 > context)
    #expect(!compactedAt.isEmpty)
    let final = PinnedContext.from(userMessages: userMessages)!
    #expect(final.decisions.count == min(steps / 10, PinnedContext.maxDecisions))
    #expect(final.tokens < budget.preserveRecent)
  }

  @Test func onlyTheUsersOwnWordsArePinned() {
    let pinned = PinnedContext.from(userMessages: ["", "Fix the build", "ok\nDecided: keep Swift 6\nDecision:   "])
    #expect(pinned?.task == "Fix the build")
    #expect(pinned?.decisions == ["keep Swift 6"])
    #expect(PinnedContext.from(userMessages: ["  "]) == nil)
    var many = PinnedContext(task: "t")
    for index in 0..<20 { many.add("d\(index)") }
    #expect(many.decisions.count == PinnedContext.maxDecisions && many.decisions.last == "d19")
  }

  @Test func theIndicatorSaysHowFullTheContextIs() {
    let meter = ContextMeter(used: 6600, context: 8192)
    #expect(meter.label == "Context 81% of 8K")
    #expect(meter.isNearlyFull)
    #expect(ContextMeter(used: 99_999, context: 8192).percent == 100)
    #expect(!ContextMeter(used: 100, context: 32768).isNearlyFull)
  }

  @Test func aCompactionIsReadFromTheEventStream() {
    let event = #"{"type":"message.part.updated","properties":{"part":{"id":"prt_9","messageID":"msg_2","type":"compaction","auto":true}}}"#
    #expect(AgentEventDecoder.decode(Data(event.utf8)) == .compacted(partID: "prt_9"))
  }
}
