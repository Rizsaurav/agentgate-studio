import Foundation
import Testing

@testable import AgentGateCore

@Suite(.serialized) struct CostLimitsTests {
  func ledger() -> (SpendLedger, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spend-\(UUID().uuidString)")
    return (SpendLedger(file: dir.appendingPathComponent("spend.json")), dir)
  }

  @Test func aTurnThatWouldGoOverItsLimitStopsWithAClearMessage() throws {
    let (l, dir) = ledger()
    defer { try? FileManager.default.removeItem(at: dir) }
    let guardian = CostGuard(limits: CloudLimits(perTurn: 0.05), ledger: l)
    guardian.beginTurn()
    try guardian.allowRequest()
    guardian.record(cost: 0.03)
    // The next reply may cost as much as the largest so far: 0.03 + 0.03 > 0.05.
    #expect(throws: CostLimitReached.turn(limit: 0.05)) { try guardian.allowRequest() }
    #expect(CostLimitReached.turn(limit: 0.05).description.contains("turn's limit of $0.05"))
    // A new turn starts from zero.
    guardian.beginTurn()
    try guardian.allowRequest()
  }

  @Test func nothingIsSentOnceTheDaysLimitIsReachedEvenAfterARestart() throws {
    let (l, dir) = ledger()
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = CostGuard(limits: CloudLimits(perDay: 0.10), ledger: l)
    first.record(cost: 0.10)
    #expect(throws: CostLimitReached.day(limit: 0.10)) { try first.allowRequest() }
    // A new app session reads the same day's total.
    let second = CostGuard(limits: CloudLimits(perDay: 0.10), ledger: l)
    #expect(second.spentToday == 0.10)
    #expect(throws: CostLimitReached.day(limit: 0.10)) { try second.allowRequest() }
  }

  @Test func theDaysTotalBelongsToTheDay() throws {
    let (l, dir) = ledger()
    defer { try? FileManager.default.removeItem(at: dir) }
    let monday = Date(timeIntervalSince1970: 1_800_000_000)
    let tuesday = monday.addingTimeInterval(86_400)
    try l.add(0.2, on: monday)
    try l.add(0.05, on: tuesday)
    #expect(abs(l.spent(on: monday) - 0.2) < 1e-9)
    #expect(abs(l.spent(on: tuesday) - 0.05) < 1e-9)
    let mode = try FileManager.default.attributesOfItem(atPath: l.file.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
  }

  @Test func theSessionLimitCountsEveryTurn() throws {
    let (l, dir) = ledger()
    defer { try? FileManager.default.removeItem(at: dir) }
    let guardian = CostGuard(limits: CloudLimits(perSession: 0.04), ledger: l)
    for _ in 0..<2 {
      guardian.beginTurn()
      try guardian.allowRequest()
      guardian.record(cost: 0.02)
    }
    guardian.beginTurn()
    #expect(throws: CostLimitReached.session(limit: 0.04)) { try guardian.allowRequest() }
  }

  @Test func noLimitsAndUnpricedRepliesNeverBlock() throws {
    let (l, dir) = ledger()
    defer { try? FileManager.default.removeItem(at: dir) }
    let guardian = CostGuard(limits: CloudLimits(perTurn: -1, perSession: .nan, perDay: 0), ledger: l)
    guardian.record(cost: nil)
    guardian.record(cost: 5)
    try guardian.allowRequest()
    #expect(guardian.unpricedReplies == 1)
  }

  @Test func limitsAreSavedCleaned() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("limits-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = CloudLimitsStore(file: dir.appendingPathComponent("limits.json"))
    try store.save(CloudLimits(perTurn: 0.5, perSession: -2, perDay: 3))
    #expect(store.load() == CloudLimits(perTurn: 0.5, perSession: nil, perDay: 3))
  }

  @Test func theAssistantSendsNothingOverTheLimitAndRecordsReportedCost() async throws {
    let (l, dir) = ledger()
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = StubReplies.session(#"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":2,"cost":0.004}}"#)
    let guardian = CostGuard(limits: CloudLimits(perDay: 0.006), ledger: l)
    var assistant = AgentAssistant(apiKey: { "k" }, session: session)
    assistant.costGuard = guardian
    _ = try await assistant.complete(["model": "m"])
    #expect(abs(guardian.spentToday - 0.004) < 1e-9)
    #expect(StubReplies.requests(session) == 1)
    await #expect(throws: CostLimitReached.day(limit: 0.006)) { try await assistant.complete(["model": "m"]) }
    #expect(StubReplies.requests(session) == 1)
  }

  @Test func openRouterRequestsAskForTheCost() {
    let body = AgentAssistant(profile: .builtIn).body(system: "s", user: "u", json: true)
    #expect((body["usage"] as? [String: Bool])?["include"] == true)
  }
}
