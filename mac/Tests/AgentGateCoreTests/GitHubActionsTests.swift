import Foundation
import Testing

@testable import AgentGateCore

private struct Canned: GitHubTransport {
  var responses: [String: Data]
  var failure: CIError?
  func get(_ path: String) async throws -> Data {
    if let failure { throw failure }
    guard let hit = responses.first(where: { path.hasPrefix($0.key) })?.value else { throw CIError.notFound }
    return hit
  }
  func post(_ path: String) async throws { if let failure { throw failure } }
}

private func run(_ id: Int, _ workflow: String, sha: String, _ status: String, _ conclusion: String?, start: Double, end: Double) -> WorkflowRun {
  WorkflowRun(
    id: id, name: workflow, display_title: "t", head_branch: "main", head_sha: sha, event: "push", status: status,
    conclusion: conclusion, run_number: id, run_attempt: 1, created_at: Date(timeIntervalSince1970: start),
    run_started_at: Date(timeIntervalSince1970: start), updated_at: Date(timeIntervalSince1970: end), html_url: "https://x", actor: nil)
}

@Suite struct GitHubActionsTests {
  @Test func remotesAreParsedStrictly() {
    let expected = GitHubRepo(owner: "Rizsaurav", name: "agentgate-studio")
    for remote in ["https://github.com/Rizsaurav/agentgate-studio.git", "https://github.com/Rizsaurav/agentgate-studio",
                   "git@github.com:Rizsaurav/agentgate-studio.git", "ssh://git@github.com/Rizsaurav/agentgate-studio\n"] {
      #expect(GitHubRepo.parse(remote) == expected, "\(remote)")
    }
    for bad in ["https://gitlab.com/a/b", "https://github.com/a", "https://github.com/a/$(whoami)", "file:///tmp/x", ""] {
      #expect(GitHubRepo.parse(bad) == nil, "\(bad)")
    }
  }

  @Test func thisProjectIsDetectedFromItsOwnGitRemote() throws {
    let found = GitHubRepo.of(folder: URL(fileURLWithPath: #filePath).deletingLastPathComponent())
    #expect(found?.repo == GitHubRepo(owner: "Rizsaurav", name: "agentgate-studio"))
  }

  @Test func realResponsesDecode() async throws {
    let service = ActionsService(repo: .init(owner: "o", name: "r"), transport: Canned(responses: [
      "repos/o/r/actions/runs?": Data(CIFixtures.runs.utf8),
      "repos/o/r/actions/runs/1/jobs": Data(CIFixtures.jobs.utf8),
    ]))
    let runs = try await service.runs()
    #expect(runs.count == 5)
    #expect(runs.allSatisfy { !$0.display_title.isEmpty && $0.html_url.hasPrefix("https://github.com/") })
    let jobs = try await service.jobs(runID: 1)
    #expect(!jobs.isEmpty && jobs.allSatisfy { !($0.steps ?? []).isEmpty })
    let progress = RunProgress.steps(jobs)
    #expect(progress.done <= progress.total && progress.total > 0)
  }

  @Test func outcomesReadPlainly() {
    #expect(Outcome(status: "completed", conclusion: "success") == .passed)
    #expect(Outcome(status: "completed", conclusion: "timed_out") == .failed)
    #expect(Outcome(status: "completed", conclusion: "cancelled") == .cancelled)
    #expect(Outcome(status: "in_progress", conclusion: nil) == .running)
    #expect(Outcome(status: "queued", conclusion: nil) == .queued)
  }

  @Test func historyCountsOnlyWhatHappened() {
    let runs = [
      run(1, "CI", sha: "a", "completed", "failure", start: 0, end: 100),
      run(2, "CI", sha: "a", "completed", "success", start: 200, end: 300),   // same commit: flaky
      run(3, "CI", sha: "b", "completed", "success", start: 400, end: 520),
      run(4, "CI", sha: "c", "completed", "cancelled", start: 600, end: 610), // not counted for pass rate
      run(5, "E2E", sha: "c", "in_progress", nil, start: 700, end: 750),
    ]
    let history = WorkflowHistory.from(runs)
    let ci = try! #require(history.first { $0.workflow == "CI" })
    #expect(ci.completed == 3 && ci.passed == 2)
    #expect(ci.flakyCommits == 1)
    #expect(ci.medianSeconds == 120)
    #expect(ci.outcomes.first == .cancelled)
    let e2e = try! #require(history.first { $0.workflow == "E2E" })
    #expect(e2e.passRate == nil && e2e.medianSeconds == nil)
    // Time left comes from the median, and only for a running run.
    #expect(RunProgress.remaining(runs[4], history: e2e) == nil)
    #expect(RunProgress.remaining(run(6, "CI", sha: "d", "in_progress", nil, start: 0, end: 0), history: ci, now: Date(timeIntervalSince1970: 50)) == 70)
  }

  @Test func logsLoseTimestampsColoursAndPrivatePaths() {
    let raw = "2026-11-05T06:30:38.1234567Z \u{1B}[31merror\u{1B}[0m in \(FileManager.default.homeDirectoryForCurrentUser.path)/x\n2026-11-05T06:30:39Z Bearer abcdef123"
    let clean = ActionsService.clean(raw, lines: 10)
    #expect(clean == "error in ~/x\nBearer <secret>")
  }

  @Test func theExcerptEndsAtTheError() {
    let raw = (["##[group]Run swift test", "Compiling", "error: cannot find 'x' in scope", "##[error]Process completed with exit code 1."]
      + (1...30).map { "cleanup \($0)" }).joined(separator: "\n")
    let clean = ActionsService.clean(raw, lines: 3)
    #expect(clean.contains("cannot find 'x'") && clean.contains("##[error]"))
    #expect(!clean.contains("cleanup 30"))
  }

  @Test func ghErrorsBecomeFixedSentences() async {
    #expect(GhCLI.error(from: "To get started with GitHub CLI, please run:  gh auth login") == .notSignedIn)
    #expect(GhCLI.error(from: "gh: Not Found (HTTP 404)") == .notFound)
    #expect(GhCLI.error(from: "API rate limit exceeded for user") == .rateLimited)
    let service = ActionsService(repo: .init(owner: "o", name: "r"), transport: Canned(responses: [:], failure: .notSignedIn))
    await #expect(throws: CIError.notSignedIn) { try await service.runs() }
    await #expect(throws: CIError.ghMissing) { try await GhCLI(executable: nil).get("x") }
  }
}
