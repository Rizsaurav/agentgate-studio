import Foundation
import Testing

@testable import AgentGateCore

private struct Reply: RepairAssistant {
  var text: String
  func propose(for report: FailureReport, removable: [String]) async throws -> String { text }
}

private actor Calls {
  var batches: [[RepairOperation]] = []
  var singles = 0
  func batch(_ operations: [RepairOperation]) { batches.append(operations) }
  func single() { singles += 1 }
}

@Suite struct RiskTiersTests {
  let small: UInt64 = 100 * 1_048_576
  let big: UInt64 = 3 * MemoryBudget.gib
  let huge: UInt64 = 20 * MemoryBudget.gib

  @Test func tier0ActsWithoutAskingAtEveryLevel() {
    for autonomy in Autonomy.allCases {
      for op in [RepairOperation.restartRuntime, .reduceContext, .setContext(8192), .retryDownload] {
        #expect(!op.needsApproval(downloadBytes: small, autonomy: autonomy), "\(op) \(autonomy)")
      }
    }
  }

  @Test func tier1AsksOnlyWhenCareful() {
    let mirror = RepairOperation.useMirror("https://hf-mirror.com")
    #expect(mirror.tier(downloadBytes: small) == .notify)
    #expect(RepairOperation.retryDownload.tier(downloadBytes: big) == .notify)
    for op in [mirror, .retryDownload] {
      #expect(op.needsApproval(downloadBytes: big, autonomy: .careful))
      #expect(!op.needsApproval(downloadBytes: big, autonomy: .balanced))
      #expect(!op.needsApproval(downloadBytes: big, autonomy: .handsOff))
    }
  }

  @Test func tier2AlwaysAsksExceptABigDownloadInHandsOff() {
    for autonomy in Autonomy.allCases {
      for op in [RepairOperation.freeDisk(modelId: "x"), .lowerQuantization, .setQuantization(.q3_K_M), .runCommand("ls")] {
        #expect(op.tier(downloadBytes: small) == .ask)
        #expect(op.needsApproval(downloadBytes: small, autonomy: autonomy), "\(op) \(autonomy)")
      }
    }
    // A re-download past the user's size limit is tier 2: asked in Careful and Balanced, noted in Hands-off.
    #expect(RepairOperation.retryDownload.tier(downloadBytes: huge) == .ask)
    #expect(RepairOperation.retryDownload.needsApproval(downloadBytes: huge, autonomy: .careful))
    #expect(RepairOperation.retryDownload.needsApproval(downloadBytes: huge, autonomy: .balanced))
    #expect(!RepairOperation.retryDownload.needsApproval(downloadBytes: huge, autonomy: .handsOff))
  }

  @Test func theSizeLimitIsTheUsers() {
    let limit = 2 * MemoryBudget.gib
    #expect(RepairOperation.retryDownload.tier(downloadBytes: big, askAboveBytes: limit) == .ask)
    #expect(RepairOperation.retryDownload.needsApproval(downloadBytes: big, autonomy: .balanced, askAboveBytes: limit))
  }

  @Test func everyLevelIsExplainedInASentence() {
    for autonomy in Autonomy.allCases {
      #expect(!autonomy.title.isEmpty)
      #expect(autonomy.summary.hasSuffix("."))
    }
  }

  fileprivate func runner(_ rig: RepairRunnerTests.Rig, reply: String, timeout: Duration = .seconds(5),
              batch: @escaping @Sendable ([RepairOperation], FailureReport) async -> Bool) -> (RepairRunner, Calls) {
    var pipeline = InstallPipeline()
    pipeline.store = rig.store
    let calls = Calls()
    var runner = RepairRunner(pipeline: pipeline, audit: rig.audit, assistant: Reply(text: reply),
                              approvalTimeout: timeout) { _, _ in await calls.single(); return true }
    runner.approveBatch = { operations, report in
      await calls.batch(operations)
      return await batch(operations, report)
    }
    return (runner, calls)
  }

  static let twoRisky = #"{"explanation":"The disk is full.","operations":[{"op":"freeDisk","modelId":"old-model"},{"op":"lowerQuantization"}]}"#

  @Test func severalApprovalsFromOneFailureAreOneQuestion() async throws {
    let rig = try RepairRunnerTests.Rig()
    defer { try? FileManager.default.removeItem(at: rig.dir) }
    let (runner, calls) = runner(rig, reply: Self.twoRisky) { _, _ in false }
    #expect(await rig.run(runner) != nil)
    #expect(await calls.batches == [[.freeDisk(modelId: "old-model"), .lowerQuantization]])
    #expect(await calls.singles == 0)
    #expect(try rig.store.load("old-model") != nil)
    #expect(rig.audit.entries().map(\.outcome) == [.proposed, .proposed, .denied, .denied])
  }

  @Test func anUnansweredQuestionTimesOutToNoAndNothingRuns() async throws {
    let rig = try RepairRunnerTests.Rig()
    defer { try? FileManager.default.removeItem(at: rig.dir) }
    let (runner, _) = runner(rig, reply: Self.twoRisky, timeout: .milliseconds(200)) { _, _ in
      // An approver who never answers: the run must not wait for it.
      try? await Task.sleep(for: .seconds(3600))
      return true
    }
    let started = Date()
    let error = await rig.run(runner)
    // Far below the approver's hour, with room for a busy CI runner.
    #expect(Date().timeIntervalSince(started) < 60)
    guard case .unrepaired(_, let why) = error else { Issue.record("expected unrepaired, got \(String(describing: error))"); return }
    #expect(why.contains("No answer came"))
    #expect(try rig.store.load("old-model") != nil)
    #expect(!rig.audit.entries().contains { $0.outcome == .done || $0.outcome == .approved })
  }
}
