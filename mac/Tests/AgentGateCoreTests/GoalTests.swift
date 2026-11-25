import Foundation
import Testing

@testable import AgentGateCore

/// The goal a session works toward in rounds: when the next round starts, and when it must stop.
@Suite struct GoalTests {
  @Test func eachRoundNamesItsNumberTheObjectiveAndTheReplyFormat() throws {
    var goal = Goal(objective: "  Make the tests pass  ", maxRounds: 3)
    let started = goal.startRound()
    let prompt = try #require(started)
    #expect(goal.objective == "Make the tests pass")
    #expect(prompt.hasPrefix("Goal round 1 of 3. Objective: Make the tests pass"))
    #expect(prompt.contains("GOAL COMPLETE:") && prompt.contains("GOAL BLOCKED:") && prompt.contains("GOAL CONTINUE:"))
    #expect(goal.roundsStarted == 1 && goal.roundsLeft == 2)
  }

  @Test func theLastMarkerLineDecidesAndFormattingAroundItIsIgnored() {
    #expect(Goal.report(in: "Fixed it.\n**GOAL COMPLETE: all 12 tests pass**") == .complete("all 12 tests pass"))
    #expect(Goal.report(in: "GOAL CONTINUE: tidy up\nGOAL BLOCKED: needs a database password") == .blocked("needs a database password"))
    #expect(Goal.report(in: "goal continue: speed up the parser") == .progress("speed up the parser"))
    #expect(Goal.report(in: "I changed two files.") == .progress(nil))
    // A marker quoted in the middle of a line is not a report.
    #expect(Goal.report(in: "I will print GOAL COMPLETE: when done") == .progress(nil))
  }

  @Test func completeStopsTheRoundsAndKeepsTheSummary() {
    var goal = Goal(objective: "x", maxRounds: 5)
    _ = goal.startRound()
    goal.finishRound(answer: "GOAL COMPLETE: done", edits: 2)
    #expect(goal.phase == .complete && goal.note == "done" && goal.filesChanged == 2)
    let next = goal.startRound()
    let resumed = goal.resume(extraRounds: 3)
    #expect(next == nil && !resumed)
  }

  @Test func roundsThatChangeNothingStopTheGoalInsteadOfLoopingForever() {
    var goal = Goal(objective: "x", maxRounds: 10)
    for round in 1...Goal.stallLimit {
      _ = goal.startRound()
      goal.finishRound(answer: "GOAL CONTINUE: look again", edits: 0)
      #expect(goal.phase == (round < Goal.stallLimit ? .active : .blocked))
    }
    #expect(goal.blocker?.contains("No file changed") == true)
  }

  @Test func anEditResetsTheStallCount() {
    var goal = Goal(objective: "x", maxRounds: 10)
    for edits in [0, 0, 1, 0, 0] {
      _ = goal.startRound()
      goal.finishRound(answer: "", edits: edits)
    }
    #expect(goal.phase == .active && goal.stalledRounds == 2)
  }

  @Test func runningOutOfRoundsBlocksAndMoreRoundsResume() throws {
    var goal = Goal(objective: "x", maxRounds: 2)
    for _ in 1...2 {
      _ = goal.startRound()
      goal.finishRound(answer: "GOAL CONTINUE: more", edits: 1)
    }
    #expect(goal.phase == .blocked && goal.roundsLeft == 0)
    #expect(goal.blocker?.contains("All 2 rounds") == true)
    let withoutMore = goal.resume()
    let withMore = goal.resume(extraRounds: 4)
    #expect(!withoutMore && withMore)
    #expect(goal.phase == .active && goal.blocker == nil && goal.maxRounds == 6)
    let third = goal.startRound()
    #expect(try #require(third).hasPrefix("Goal round 3 of 6."))
  }

  @Test func theAgentCanSayItIsBlockedAndAFailedRoundBlocksToo() {
    var goal = Goal(objective: "x")
    _ = goal.startRound()
    goal.finishRound(answer: "GOAL BLOCKED:", edits: 0)
    #expect(goal.phase == .blocked && goal.blocker == "The agent needs your input to go on.")

    var failed = Goal(objective: "x")
    _ = failed.startRound()
    failed.failRound("the engine stopped")
    #expect(failed.phase == .blocked && failed.blocker == "A round failed: the engine stopped")
  }

  @Test func pausedGoalsIgnoreTheRoundThatWasStoppedAndResumeLater() throws {
    var goal = Goal(objective: "x", maxRounds: 4)
    _ = goal.startRound()
    goal.pause()
    goal.finishRound(answer: "GOAL COMPLETE: no", edits: 3)
    #expect(goal.phase == .paused && goal.filesChanged == 0)
    let whilePaused = goal.startRound()
    let resumed = goal.resume()
    let second = goal.startRound()
    #expect(whilePaused == nil && resumed)
    #expect(try #require(second).hasPrefix("Goal round 2 of 4."))
  }

  @Test func roundCapsAreBounded() {
    #expect(Goal(objective: "x", maxRounds: 0).maxRounds == 1)
    #expect(Goal(objective: "x", maxRounds: 999).maxRounds == Goal.maxRoundsLimit)
  }

  @Test func goalsSurviveASaveAndOldSessionsStillLoad() throws {
    var goal = Goal(objective: "ship it", maxRounds: 3, startedAt: Date(timeIntervalSince1970: 0))
    _ = goal.startRound()
    goal.finishRound(answer: "GOAL CONTINUE: next", edits: 1)
    let decoded = try JSONDecoder().decode(Goal.self, from: JSONEncoder().encode(goal))
    #expect(decoded == goal)

    let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","projectId":"6F9619FF-8B86-D011-B42D-00C04FC964FF","modelId":"m","modelName":"M","createdAt":0,"messages":[]}"#
    let session = try JSONDecoder().decode(Session.self, from: Data(old.utf8))
    #expect(session.goal == nil)
  }

  @Test func aClaimedCompletionWithoutAPassingCheckIsCheckedFirst() throws {
    var goal = Goal(objective: "Make the tests pass", maxRounds: 4, check: "python3 -m unittest")
    _ = goal.startRound()
    goal.finishRound(answer: "GOAL COMPLETE: fixed", edits: 1, checkPassed: nil)
    #expect(goal.phase == .active && goal.verifying)
    let checkRound = goal.startRound()
    #expect(try #require(checkRound).contains("Run `python3 -m unittest` now"))
    goal.finishRound(answer: "GOAL COMPLETE: fixed", edits: 0, checkPassed: false)
    #expect(goal.phase == .active && !goal.verifying && goal.note?.contains("did not pass") == true)
    _ = goal.startRound()
    goal.finishRound(answer: "Ran it, all green.\nGOAL COMPLETE: fixed", edits: 1, checkPassed: true)
    #expect(goal.phase == .complete)
  }

  @Test func aCompletionThatRanTheCheckInTheSameRoundIsAccepted() {
    var goal = Goal(objective: "x", check: "swift test")
    _ = goal.startRound()
    goal.finishRound(answer: "GOAL COMPLETE: done", edits: 1, checkPassed: true)
    #expect(goal.phase == .complete && !goal.verifying)
  }

  @Test func theLastRunOfTheCheckDecidesWhetherItPassed() {
    let goal = Goal(objective: "x", check: "python3 -m unittest")
    #expect(goal.checkResult(commands: [("python3 -m unittest", 1), ("python3  -m unittest -v", 0)]) == true)
    #expect(goal.checkResult(commands: [("python3 -m unittest", 0), ("cd . && python3 -m unittest", 1)]) == false)
    #expect(goal.checkResult(commands: [("ls", 0)]) == nil)
    #expect(goal.checkResult(commands: [("python3 -m unittest", nil)]) == nil)
    #expect(Goal(objective: "x").checkResult(commands: [("anything", 0)]) == nil)
  }

  @Test func theOptimizeObjectiveNamesTheProjectsOwnCheck() {
    #expect(Goal.optimize(testCommand: "swift test").contains("Verify every change with `swift test`."))
    #expect(Goal.optimize(testCommand: nil).contains("Find the project's build or tests"))
  }
}

/// What a project folder holds, for its overview and the goal's objective.
@Suite struct RepoScanTests {
  @Test func theTestCommandComesFromTheProjectsOwnFiles() {
    func command(_ files: [String: String]) -> String? {
      RepoScan.testCommand(files: Set(files.keys)) { files[$0] }
    }
    #expect(command(["Package.swift": ""]) == "swift test")
    #expect(command(["package.json": #"{"scripts":{"test":"vitest run"}}"#, "pnpm-lock.yaml": ""]) == "pnpm test")
    #expect(command(["package.json": #"{"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}"#]) == nil)
    #expect(command(["Cargo.toml": ""]) == "cargo test")
    #expect(command(["go.mod": ""]) == "go test ./...")
    #expect(command(["Makefile": "build:\n\tcc main.c\ntest:\n\t./run"]) == "make test")
    #expect(command(["pyproject.toml": "[tool.pytest.ini_options]", "app.py": ""]) == "python3 -m pytest")
    #expect(command(["cart.py": "", "test_cart.py": ""]) == "python3 -m unittest")
    #expect(command(["README.md": ""]) == nil)
  }

  @Test func languagesAreRankedAndTheLongTailIsFolded() {
    let ranked = RepoScan.rank(["Swift": (10, 900), "Python": (2, 95), "Shell": (1, 5)])
    #expect(ranked.map(\.name) == ["Swift", "Python", "Other"])
    #expect(abs(ranked[0].share - 0.9) < 0.0001)
    #expect(ranked.last?.lines == 5)
  }

  @Test func aRealFolderIsScannedWithItsGitState() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("node_modules/x"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try "a = 1\nb = 2\n".write(to: folder.appendingPathComponent("cart.py"), atomically: true, encoding: .utf8)
    try "import unittest\n".write(to: folder.appendingPathComponent("test_cart.py"), atomically: true, encoding: .utf8)
    try "ignored\n".write(to: folder.appendingPathComponent("node_modules/x/dep.js"), atomically: true, encoding: .utf8)

    let plain = try #require(RepoScan.scan(folder))
    #expect(!plain.isGit && plain.files == 2 && plain.lines == 3)
    #expect(plain.languages.map(\.name) == ["Python"] && plain.testCommand == "python3 -m unittest")

    let git = { (args: [String]) in _ = Git.run(["-C", folder.path] + args, timeout: 10) }
    git(["init", "-q", "-b", "main"])
    try "node_modules/\n".write(to: folder.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    git(["add", "."])
    git(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "first commit"])
    try "a = 1\nb = 3\n".write(to: folder.appendingPathComponent("cart.py"), atomically: true, encoding: .utf8)

    let scanned = try #require(RepoScan.scan(folder))
    #expect(scanned.isGit && scanned.branch == "main" && scanned.lastCommit == "first commit")
    #expect(scanned.changed == 1 && scanned.files == 3 && scanned.lines == 3)
  }

  @Test func aLongFileListDoesNotStallTheRunner() {
    // Far more output than a pipe's buffer: read while the command runs, not after it exits.
    let result = Git.run(["-c", "yes x | head -c 400000"], exe: "/bin/sh", timeout: 10)
    #expect(result.output?.count == 400_000 && !result.timedOut)
  }
}
