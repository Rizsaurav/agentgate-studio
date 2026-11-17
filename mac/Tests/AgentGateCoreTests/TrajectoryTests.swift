import Foundation
import Testing

@testable import AgentGateCore

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent()
private let suite = repo.appendingPathComponent("evals/trajectory")

@Suite struct TrajectoryTests {
  private let tasks = try! TrajectoryTask.loadAll(from: suite)

  /// A copy of the task's project in a temporary parent, edited by `solve`, then scored.
  private func score(_ id: String, answer: String = "", solve: (URL) throws -> Void = { _ in }) throws -> String? {
    let (task, project) = try #require(tasks.first { $0.task.id == id })
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent("traj-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: parent) }
    let folder = parent.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: project, to: folder)
    try solve(folder)
    return TrajectoryScorer.check(task, folder: folder, original: project, answer: answer)
  }

  private func replace(_ folder: URL, _ path: String, _ old: String, _ new: String) throws {
    let url = folder.appendingPathComponent(path)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains(old), "\(path) has no \(old)")
    try text.replacingOccurrences(of: old, with: new).write(to: url, atomically: true, encoding: .utf8)
  }

  @Test func committedSuiteCoversEveryKind() {
    #expect(tasks.count == 7)
    #expect(Set(tasks.map(\.task.kind)) == Set(TrajectoryTask.kinds))
  }

  // MARK: Reference solutions pass; the untouched project and wrong solutions fail

  @Test func readAndSearchAreScoredOnTheAnswer() throws {
    #expect(try score("read-config", answer: "The region is eu-north-2.") == nil)
    #expect(try score("read-config", answer: "I could not find it.") != nil)
    #expect(try score("search-definition", answer: "It is in shop/billing/invoice.py") == nil)
    #expect(try score("search-definition", answer: "shop/module_3.py") != nil)
  }

  @Test func fixingTheCodePassesAndEditingTheTestDoesNot() throws {
    #expect(try score("fix-failing-test") != nil)
    #expect(try score("fix-failing-test") { try self.replace($0, "calc.py", "return a - b", "return a + b") } == nil)
    // Making the test agree with the bug is not a fix.
    #expect(try score("fix-failing-test") { try self.replace($0, "test_calc.py", "add(2, 3), 5", "add(2, 3), -1") } != nil)
  }

  @Test func theFeatureNeedsCodeAndATest() throws {
    let code = "\n\ndef slugify(text):\n    return text.lower().replace(' ', '-')\n"
    let test = "    def test_slugify(self):\n        from text_utils import slugify\n        self.assertEqual(slugify('Hello World'), 'hello-world')\n\n\nif __name__"
    #expect(try score("add-feature-with-test") != nil)
    #expect(try score("add-feature-with-test") { folder in
      let url = folder.appendingPathComponent("text_utils.py")
      try (try String(contentsOf: url, encoding: .utf8) + code).write(to: url, atomically: true, encoding: .utf8)
    } != nil, "code without a test must fail")
    #expect(try score("add-feature-with-test") { folder in
      let url = folder.appendingPathComponent("text_utils.py")
      try (try String(contentsOf: url, encoding: .utf8) + code).write(to: url, atomically: true, encoding: .utf8)
      try self.replace(folder, "test_text_utils.py", "\n\nif __name__", "\n" + test)
    } == nil)
  }

  @Test func writingOutsideTheProjectFails() throws {
    #expect(try score("refuse-outside") == nil)
    #expect(try score("refuse-outside") { try "hello".write(to: $0.deletingLastPathComponent().appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8) } != nil)
  }

  @Test func theBrokenBuildMustBeRepaired() throws {
    #expect(try score("recover-failing-command") != nil)
    #expect(try score("recover-failing-command") { try self.replace($0, "build.sh", "make_reprot.py", "make_report.py") } == nil)
  }

  @Test func aRenameMustReachEveryFile() throws {
    func rename(_ folder: URL, files: [String]) throws {
      for file in files { try replace(folder, file, "get_user", "fetch_user") }
    }
    #expect(try score("multi-file-rename") != nil)
    #expect(try score("multi-file-rename") { try rename($0, files: ["users.py", "profile.py"]) } != nil, "a partial rename must fail")
    #expect(try score("multi-file-rename") { try rename($0, files: ["users.py", "profile.py", "admin.py", "test_users.py"]) } == nil)
  }

  // MARK: Rules used without a person

  @Test func callsAreAnsweredByTheAppsRules() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("traj-rules-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    func allowed(_ tool: String, _ detail: String) -> Bool {
      TrajectoryRunner.allowed(AgentEvent.Permission(id: "1", tool: tool, detail: detail), folder: folder)
    }
    #expect(allowed("read", "calc.py"))
    #expect(allowed("edit", "calc.py"))
    #expect(allowed("bash", "python3 -m unittest -q"))
    #expect(!allowed("read", "/etc/hosts"))
    #expect(!allowed("write", "../outside.txt"))
    #expect(!allowed("webfetch", "https://example.com"))
    #expect(!allowed("bash", "rm -rf ~"))
  }

  // MARK: Regressions

  private func report(_ passes: [String: Int], flaky: [String] = []) -> TrajectoryReport {
    var score = ToolScoreReport(
      model: "m", quant: "Q8_0", engine: "e", commit: "c", hardware: "h", date: "2026-11-17", temperature: 0, seed: 42,
      cases: passes.keys.sorted().map { CaseOutcome(id: $0, category: "read", runs: 2, passes: passes[$0]!, reason: "", seconds: 1) })
    score.knownFlaky = flaky
    return TrajectoryReport(score: score, records: [])
  }

  @Test func aTaskThatPassedMustStillPassUnlessItIsFlaky() {
    let base = [report(["a": 2, "b": 2, "c": 0])]
    #expect(TrajectoryReport.regressions(base: base, head: [report(["a": 2, "b": 2, "c": 2])]).isEmpty)
    #expect(TrajectoryReport.regressions(base: base, head: [report(["a": 0, "b": 2, "c": 0])]) == ["m-Q8_0: a passed before and fails now"])
    #expect(TrajectoryReport.regressions(base: base, head: [report(["a": 0, "b": 2, "c": 0], flaky: ["a"])]).isEmpty)
    #expect(TrajectoryReport.regressions(base: base, head: []).first?.contains("removed") == true)
  }

  @Test func committedResultsMatchTheSuiteAndTheDoc() throws {
    let reports = try TrajectoryReport.loadAll(from: suite.appendingPathComponent("results"))
    for r in reports { #expect(Set(r.score.cases.map(\.id)) == Set(tasks.map(\.task.id)), "\(r.score.key) was run on other tasks") }
    let doc = try String(contentsOf: repo.appendingPathComponent("docs/TRAJECTORY_SCORES.md"), encoding: .utf8)
    #expect(doc == TrajectoryReport.markdown(reports), "docs/TRAJECTORY_SCORES.md is stale: run agentgate-tooleval trajectory-report")
  }
}
