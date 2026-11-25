import Foundation
import Testing

@testable import AgentGateCore

/// What a turn changed, measured with git against the moment before it.
@Suite struct TurnChangesTests {
  @Test func gitsOutputBecomesChangesWithTheirKind() {
    let numstat = "3\t1\tcart.py\0" + "10\t0\tnew.py\0" + "0\t7\told.py\0" + "-\t-\tlogo.png\0"
    let status = "M\0cart.py\0A\0new.py\0D\0old.py\0M\0logo.png\0"
    let changes = TurnBaseline.parse(numstat: numstat, status: status)
    #expect(changes.map(\.path) == ["cart.py", "new.py", "old.py", "logo.png"])
    #expect(changes.map(\.kind) == [.modified, .added, .deleted, .modified])
    #expect(changes[0].added == 3 && changes[0].removed == 1 && changes[3].added == 0)
  }

  @Test func onlyWhatTheTurnChangedIsCountedNotEarlierUncommittedWork() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("turn-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let write = { (name: String, text: String) in
      try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let git = { (args: [String]) in _ = Git.run(["-C", folder.path] + args, timeout: 10) }
    #expect(TurnBaseline.capture(folder) == nil, "Not a repository yet.")
    git(["init", "-q", "-b", "main"])
    try write("a.py", "1\n2\n3\n")
    try write("b.py", "x\n")
    git(["add", "."])
    git(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "base"])
    // Work the user had not committed before the turn: not the turn's doing.
    try write("a.py", "1\n2\n3\n4\n")
    try write("notes.txt", "draft\n")

    let baseline = try #require(TurnBaseline.capture(folder))
    #expect(Git.run(["-C", folder.path, "stash", "list"], timeout: 10).output?.isEmpty == true, "The stash list is untouched.")
    // The turn: one line changed in a.py, b.py deleted, a new file, and the untracked note edited.
    try write("a.py", "1\n2\nthree\n4\n")
    try FileManager.default.removeItem(at: folder.appendingPathComponent("b.py"))
    try write("c.py", "new\nfile\n")
    try write("notes.txt", "draft\nmore\n")

    let changes = baseline.changes(in: folder)
    let byPath = Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0) })
    #expect(Set(byPath.keys) == ["a.py", "b.py", "c.py", "notes.txt"])
    #expect(byPath["a.py"]?.added == 1 && byPath["a.py"]?.removed == 1 && byPath["a.py"]?.kind == .modified)
    #expect(byPath["b.py"]?.kind == .deleted && byPath["b.py"]?.removed == 1)
    #expect(byPath["c.py"]?.kind == .added && byPath["c.py"]?.added == 2)
    #expect(byPath["notes.txt"]?.kind == .modified)
    #expect(try String(contentsOf: folder.appendingPathComponent("a.py"), encoding: .utf8) == "1\n2\nthree\n4\n")
  }
}

/// Finding past chats by what was said and done in them.
@Suite struct SessionSearchTests {
  func session(_ texts: [String], steps: [AgentStep] = [], goal: String? = nil, day: Double = 0) -> Session {
    var s = Session(
      id: UUID(), projectId: UUID(), modelId: "m", modelName: "M", createdAt: Date(timeIntervalSince1970: day * 86_400),
      messages: texts.map { ChatMessage(role: .user, content: $0) })
    if !steps.isEmpty { s.messages.append(ChatMessage(role: .assistant, content: "done", steps: steps)) }
    if let goal { s.goal = Goal(objective: goal) }
    return s
  }

  @Test func everyWordMustMatchAndMoreMatchesRankFirst() {
    let a = session(["fix the cart subtotal bug"])
    let b = session(["the cart total is wrong", "cart cart"])
    let c = session(["unrelated"])
    let hits = SessionSearch.search("cart", in: [a, b, c])
    #expect(hits.map(\.sessionId) == [b.id, a.id])
    #expect(SessionSearch.search("cart subtotal", in: [a, b, c]).map(\.sessionId) == [a.id])
    #expect(SessionSearch.search("x", in: [a]).isEmpty, "One-letter queries match nothing.")
  }

  @Test func commandsFilesAndGoalsAreSearchableToo() {
    let step = AgentStep(id: "s", kind: .tool, tool: "bash", text: "python3 -m pytest tests/test_parser.py", status: .done)
    let withStep = session(["run the tests"], steps: [step])
    let withGoal = session([], goal: "Optimize the parser")
    #expect(SessionSearch.search("test_parser", in: [withStep, withGoal]).map(\.sessionId) == [withStep.id])
    #expect(SessionSearch.search("parser", in: [withStep, withGoal]).count == 2)
  }

  @Test func theSnippetShowsTheTextAroundTheMatch() {
    let long = String(repeating: "lorem ", count: 40) + "the needle is here " + String(repeating: "ipsum ", count: 40)
    let hit = SessionSearch.search("needle", in: [session([long])]).first
    #expect(hit?.snippet.contains("the needle is here") == true)
    #expect(hit?.snippet.hasPrefix("…") == true && hit?.snippet.hasSuffix("…") == true)
  }
}

/// When a scheduled task is due.
@Suite struct ScheduleTests {
  var calendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }

  func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

  @Test func aDailyTaskIsDueOnceItsTimeHasPassedAndNotAgainThatDay() {
    var task = ScheduledTask(projectId: UUID(), text: "run tests", hour: 9, minute: 0, createdAt: date("2026-11-20T08:00:00Z"))
    #expect(!task.isDue(at: date("2026-11-20T08:59:00Z"), calendar: calendar))
    #expect(task.isDue(at: date("2026-11-20T09:00:00Z"), calendar: calendar))
    task.lastRun = date("2026-11-20T09:00:30Z")
    #expect(!task.isDue(at: date("2026-11-20T18:00:00Z"), calendar: calendar))
    #expect(task.isDue(at: date("2026-11-21T09:01:00Z"), calendar: calendar))
  }

  @Test func missedRunsHappenOnceNotOncePerMissedDay() {
    var task = ScheduledTask(projectId: UUID(), text: "t", hour: 9, minute: 0, createdAt: date("2026-11-01T00:00:00Z"))
    task.lastRun = date("2026-11-10T09:00:00Z")
    let now = date("2026-11-15T12:00:00Z")
    #expect(task.isDue(at: now, calendar: calendar))
    #expect(task.lastSlot(before: now, calendar: calendar) == date("2026-11-15T09:00:00Z"))
    task.lastRun = now
    #expect(!task.isDue(at: now.addingTimeInterval(60), calendar: calendar))
  }

  @Test func weekdayTasksSkipTheWeekendAndNewTasksDoNotRunForThePast() {
    // 2026-11-21 is a Saturday.
    let task = ScheduledTask(
      projectId: UUID(), text: "t", hour: 9, minute: 0, weekdays: [2, 3, 4, 5, 6], createdAt: date("2026-11-20T10:00:00Z"))
    #expect(!task.isDue(at: date("2026-11-21T12:00:00Z"), calendar: calendar), "Friday's 9:00 was before it was created.")
    #expect(!task.isDue(at: date("2026-11-22T12:00:00Z"), calendar: calendar))
    #expect(task.isDue(at: date("2026-11-23T09:05:00Z"), calendar: calendar))
    #expect(task.summary(calendar: calendar) == "Weekdays at 09:00")
  }

  @Test func disabledTasksNeverRunAndTasksSurviveASave() throws {
    var task = ScheduledTask(projectId: UUID(), text: "t", asGoal: true, hour: 25, minute: -3, createdAt: date("2026-11-01T00:00:00Z"))
    #expect(task.hour == 23 && task.minute == 0)
    task.enabled = false
    #expect(!task.isDue(at: date("2026-11-30T23:30:00Z"), calendar: calendar))
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("sched-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let store = ScheduleStore(file: file)
    try store.save([task])
    #expect(store.load() == [task])
  }
}
