import Foundation
import Testing

@testable import AgentGateCore

/// The repository root, found from this file so the tests read the committed suite and results.
private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent()
private let suiteFolder = repo.appendingPathComponent("evals/tools")

private func item(_ expect: ToolExpectation, tools: [String] = ["get_weather", "lookup_user"]) -> ToolCase {
  ToolCase(id: "t", category: "single", description: "", tools: tools, messages: [.object(["role": .string("user"), "content": .string("hi")])], expect: expect)
}

private func made(_ name: String, _ arguments: [String: JSONValue]?) -> MadeCall { MadeCall(name: name, arguments: arguments) }

private func outcome(_ id: String, _ passes: Int, of runs: Int = 1) -> CaseOutcome {
  CaseOutcome(id: id, category: "single", runs: runs, passes: passes, reason: passes == runs ? "" : "x", seconds: 1)
}

private func report(_ model: String, passed: Int, of total: Int = 40) -> ToolScoreReport {
  ToolScoreReport(
    model: model, quant: "Q8_0", engine: "llama.cpp test", commit: "abc", hardware: "test", date: "2026-11-17",
    temperature: 0, seed: 42, cases: (0..<total).map { outcome("c\($0)", $0 < passed ? 1 : 0) })
}

@Suite struct ToolSuiteTests {
  // MARK: The committed suite

  @Test func committedSuiteIsValidAndCoversEveryCategory() throws {
    let suite = try ToolSuite.load(from: suiteFolder)
    #expect(suite.cases.count >= ToolSuite.minimumCases)
    for category in ToolSuite.categories {
      #expect(suite.cases.contains { $0.category == category }, "no case in \(category)")
    }
  }

  @Test func committedResultsParseAndTheScoresDocIsUpToDate() throws {
    let reports = try ToolScoreReport.loadAll(from: suiteFolder.appendingPathComponent("results"))
    let suite = try ToolSuite.load(from: suiteFolder)
    for r in reports {
      // Results must be from the current suite: rerun the models after changing cases.
      #expect(Set(r.cases.map(\.id)) == Set(suite.cases.map(\.id)), "\(r.key) was measured on a different suite")
    }
    let doc = try String(contentsOf: repo.appendingPathComponent("docs/MODEL_SCORES.md"), encoding: .utf8)
    #expect(doc == ToolScoreReport.markdown(reports), "docs/MODEL_SCORES.md is stale: run agentgate-tooleval report")
  }

  @Test func catalogScoresMatchTheCommittedResults() throws {
    let catalog = try Catalog.bundled()
    let reports = try ToolScoreReport.loadAll(from: suiteFolder.appendingPathComponent("results"))
    for model in catalog.models {
      let mine = reports.filter { $0.model == model.id }.sorted { Quantization(rawValue: $0.quant)! > Quantization(rawValue: $1.quant)! }
      guard let best = mine.first else {
        #expect(model.toolScore == nil, "\(model.id) has a score but no results")
        continue
      }
      #expect(model.toolScore?.quant == best.quant, "run build_catalog.py --scores")
      #expect(abs((model.toolScore?.passRate ?? -1) - best.passRate) < 0.0001, "run build_catalog.py --scores")
    }
  }

  // MARK: Validation

  @Test func suiteValidationRejectsMistakes() {
    let tool: JSONValue = .object(["type": .string("function"), "function": .object(["name": .string("get_weather")])])
    let good = item(.init(calls: [.init(name: "get_weather")]), tools: ["get_weather"])
    var unknownTool = good
    unknownTool.tools = ["nope"]
    var notOffered = good
    notOffered.expect = .init(calls: [.init(name: "lookup_user")])
    var twoMatchers = good
    twoMatchers.expect = .init(calls: [.init(name: "get_weather", arguments: ["city": .init(equals: .string("a"), contains: "a")])])
    var both = good
    both.expect = .init(calls: [.init(name: "get_weather")], noCall: true)
    for bad in [unknownTool, notOffered, twoMatchers, both] {
      #expect(throws: ToolSuiteError.self) { try bad.validate(knownTools: ["get_weather"]) }
    }
    #expect(throws: ToolSuiteError.self) { try ToolSuite(tools: ["get_weather": tool], cases: [good, good]).validate() }
  }

  // MARK: Scoring

  @Test func aCorrectCallPassesAndNumbersCompareAsNumbers() {
    let c = item(.init(calls: [.init(name: "get_weather", arguments: ["city": .init(contains: "paris"), "days": .init(equals: .number(3))])]))
    #expect(ToolSuite.score(c, calls: [made("get_weather", ["city": .string("Paris, FR"), "days": .number(3.0)])], text: "") == nil)
  }

  @Test func wrongToolMissingArgumentAndExtraCallsFail() {
    let c = item(.init(calls: [.init(name: "get_weather", arguments: ["city": .init(contains: "paris")])]))
    #expect(ToolSuite.score(c, calls: [], text: "It is sunny") != nil)
    #expect(ToolSuite.score(c, calls: [made("lookup_user", ["email": .string("a")])], text: "") != nil)
    #expect(ToolSuite.score(c, calls: [made("get_weather", [:])], text: "")?.contains("missing") == true)
    #expect(ToolSuite.score(c, calls: [made("get_weather", ["city": .string("Paris")]), made("get_weather", ["city": .string("Rome")])], text: "") != nil)
  }

  @Test func argumentsThatAreNotAnObjectAreMalformed() {
    let c = item(.init(calls: [.init(name: "get_weather")]))
    #expect(ToolSuite.score(c, calls: [made("get_weather", nil)], text: "")?.contains("not a JSON object") == true)
    let (calls, _) = ToolSuiteRunner.parse(["tool_calls": [["function": ["name": "get_weather", "arguments": "{city: Paris"]]]])
    #expect(calls == [made("get_weather", nil)])
  }

  @Test func nestedObjectsAreMatchedFieldByField() {
    let c = item(.init(calls: [.init(name: "get_weather", arguments: ["where": .init(object: ["city": .init(contains: "berlin")])])]))
    #expect(ToolSuite.score(c, calls: [made("get_weather", ["where": .object(["city": .string("Berlin"), "room": .string("4")])])], text: "") == nil)
    #expect(ToolSuite.score(c, calls: [made("get_weather", ["where": .string("Berlin")])], text: "") != nil)
  }

  @Test func parallelCallsMatchInAnyOrderUnlessOrdered() {
    let calls = [made("get_weather", ["city": .string("London")]), made("get_weather", ["city": .string("Paris")])]
    let wanted: [ExpectedCall] = [.init(name: "get_weather", arguments: ["city": .init(contains: "paris")]), .init(name: "get_weather", arguments: ["city": .init(contains: "london")])]
    #expect(ToolSuite.score(item(.init(calls: wanted)), calls: calls, text: "") == nil)
    #expect(ToolSuite.score(item(.init(calls: wanted, ordered: true)), calls: calls, text: "") != nil)
    // One made call cannot satisfy two expected calls.
    #expect(ToolSuite.score(item(.init(calls: wanted)), calls: [calls[1], calls[1]], text: "") != nil)
  }

  @Test func noCallCasesCheckTheAnswerText() {
    let c = item(.init(noCall: true, answerContains: ["144"]))
    #expect(ToolSuite.score(c, calls: [], text: "12 × 12 = 144.") == nil)
    #expect(ToolSuite.score(c, calls: [], text: "I am not sure.") != nil)
    #expect(ToolSuite.score(c, calls: [made("get_weather", [:])], text: "144") != nil)
  }

  // MARK: Readiness rule and regression gate

  @Test func readinessNeedsTheProbeAndTheMeasuredBar() {
    #expect(ToolSuite.readiness(probe: .chatOnly, measured: 1) == .chatOnly)
    #expect(ToolSuite.readiness(probe: .ready, measured: nil) == .ready)
    #expect(ToolSuite.readiness(probe: .ready, measured: ToolSuite.readyPassRate) == .ready)
    #expect(ToolSuite.readiness(probe: .ready, measured: ToolSuite.readyPassRate - 0.01) == .chatOnly)
  }

  @Test func regressionGateFailsOnlyBeyondTheMargin() {
    let base = [report("a", passed: 32), report("b", passed: 32)]
    #expect(ToolScoreReport.regressions(base: base, head: [report("a", passed: 30), report("b", passed: 34)]).isEmpty)
    let dropped = ToolScoreReport.regressions(base: base, head: [report("a", passed: 29), report("b", passed: 32)])
    #expect(dropped.count == 1 && dropped[0].hasPrefix("a-Q8_0"))
    #expect(ToolScoreReport.regressions(base: base, head: [report("a", passed: 32)]).first?.contains("removed") == true)
    // A new model is not a regression.
    #expect(ToolScoreReport.regressions(base: [], head: base).isEmpty)
  }

  // MARK: Repeats and flakiness

  @Test func runsMergeByMajorityAndDisagreementIsFlaky() {
    let merged = ToolSuiteRunner.merge([[outcome("a", 1), outcome("b", 1)], [outcome("a", 1), outcome("b", 0)], [outcome("a", 1), outcome("b", 0)]])
    #expect(merged.map(\.runs) == [3, 3])
    #expect(merged[0].passed && !merged[0].flaky)
    #expect(!merged[1].passed && merged[1].flaky)
  }

  @Test func aCaseThatFlipsBetweenRunsStaysListedAsFlaky() {
    let first = ToolScoreReport(model: "m", quant: "Q8_0", engine: "e", commit: "c", hardware: "h", date: "2026-11-17", temperature: 0, seed: 42,
                                cases: [outcome("a", 3, of: 3), outcome("b", 0, of: 3)])
    let second = ToolScoreReport(model: "m", quant: "Q8_0", engine: "e", commit: "c", hardware: "h", date: "2026-11-17", temperature: 0, seed: 42,
                                 cases: [outcome("a", 0, of: 3), outcome("b", 0, of: 3)]).carryingFlakes(from: first)
    #expect(second.flaky == ["a"])
    // A third run that agrees with the second still lists it.
    let third = ToolScoreReport(model: "m", quant: "Q8_0", engine: "e", commit: "c", hardware: "h", date: "2026-11-17", temperature: 0, seed: 42,
                                cases: [outcome("a", 0, of: 3), outcome("b", 0, of: 3)]).carryingFlakes(from: second)
    #expect(third.flaky == ["a"])
  }

  // MARK: Runner against a scripted endpoint

  @Test func runnerScoresWhatTheEndpointReturns() async throws {
    let reply = #"{"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"1","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}}]}}]}"#
    let server = try TestHTTPServer(body: Data(reply.utf8), servedPath: "/v1/chat/completions")
    defer { server.stop() }
    let tool: JSONValue = .object(["type": .string("function"), "function": .object(["name": .string("get_weather")])])
    var pass = item(.init(calls: [.init(name: "get_weather", arguments: ["city": .init(contains: "paris")])]), tools: ["get_weather"])
    pass.id = "pass"
    var fail = item(.init(noCall: true), tools: ["get_weather"])
    fail.id = "fail"
    let suite = ToolSuite(tools: ["get_weather": tool], cases: [pass, fail])
    let runner = ToolSuiteRunner(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, apiKey: "k", model: "m")
    let outcomes = try await runner.run(suite)
    #expect(outcomes.map(\.passed) == [true, false])
    #expect(outcomes[1].reason.contains("get_weather"))
  }
}
