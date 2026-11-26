import Foundation
import Testing

@testable import AgentGateCore

/// The visible transcript of a turn, built from the harness's real event stream.
@Suite struct TranscriptTests {
  func decoded() -> [AgentEvent] {
    AgentTurnFixture.events.compactMap { AgentEventDecoder.decode(Data($0.utf8)) }
  }

  @Test func aRecordedTurnShowsEveryStepInOrderWithoutTheUsersOwnMessage() throws {
    var transcript = Transcript()
    for event in decoded() { transcript.apply(event) }
    let steps = transcript.steps
    #expect(steps.map(\.kind) == [.tool, .tool, .text])
    #expect(!steps.contains { $0.text.contains("Do these two things") })
    #expect(transcript.answer == "DONE")

    let bash = steps[0]
    #expect(bash.tool == "bash")
    #expect(bash.text == "for i in 1 2 3 4; do echo step $i; sleep 1; done; ls -la; exit 3")
    #expect(bash.output.hasPrefix("step 1\nstep 2\nstep 3\nstep 4\n"))
    #expect(bash.exitCode == 3)
    // A command that exits non-zero is a failure, even though the harness says "completed".
    #expect(bash.status == .failed)
    let duration = try #require(bash.duration)
    #expect(duration > 3.5 && duration < 6)

    let edit = steps[1]
    #expect(edit.tool == "edit" && edit.status == .done)
    #expect(edit.text == "/work/proj/app.py")
    #expect(edit.diffCounts?.added == 1 && edit.diffCounts?.removed == 1)
    #expect(edit.diff?.contains("+def greet(name): return \"hello \" + name") == true)
  }

  @Test func aRunningCommandShowsItsOutputAsItArrives() {
    var transcript = Transcript()
    var seen: [String] = []
    for event in decoded() {
      transcript.apply(event)
      if let running = transcript.running, running.tool == "bash", seen.last != running.output {
        seen.append(running.output)
      }
    }
    // Empty, then one more line each second, before the command ended.
    #expect(seen.contains("step 1\n"))
    #expect(seen.contains("step 1\nstep 2\n"))
    #expect(seen.contains("step 1\nstep 2\nstep 3\n"))
    #expect(transcript.running == nil)
  }

  @Test func usageAddsUpTheModelCalls() {
    var transcript = Transcript()
    for event in decoded() { transcript.apply(event) }
    #expect(transcript.usage.tokensIn > 10_000)
    #expect(transcript.usage.tokensOut > 0)
  }

  @Test func reasoningIsKeptApartFromTheAnswer() {
    var transcript = Transcript()
    transcript.apply(.message(id: "m", role: "assistant"))
    transcript.apply(.reasoning(partID: "r", messageID: "m", text: ""))
    transcript.apply(.textDelta(partID: "r", messageID: "m", delta: "Let me look"))
    transcript.apply(.textDelta(partID: "t", messageID: "m", delta: "Hello"))
    #expect(transcript.steps.map(\.kind) == [.reasoning, .text])
    #expect(transcript.steps[0].text == "Let me look")
    #expect(transcript.answer == "Hello")
  }

  @Test func aRefusalBeforeItsCallAppearsIsStillOneStep() {
    var transcript = Transcript()
    transcript.refuse(id: "blocked-per_1", tool: "bash", detail: "rm -rf /", reason: "outside-project", callID: "c1")
    transcript.apply(.tool(.init(
      id: "prt_9", name: "bash", status: "error", detail: "rm -rf /", output: "", callID: "c1",
      error: "The user rejected permission to use this specific tool call with the following feedback: …")))
    #expect(transcript.steps.count == 1)
    #expect(transcript.steps[0].status == .refused)
    #expect(transcript.steps[0].output == "outside-project")
  }

  // Seen in the app: the harness shows the call, the app refuses it, and the harness may never update
  // that call again. One card, refused, not one "running" forever beside a second "blocked" one.
  @Test func aRefusalReplacesItsCallAndKeepsItsReadablePath() {
    var transcript = Transcript()
    transcript.apply(.tool(.init(id: "prt_1", name: "read", status: "pending", detail: "", output: "", callID: "c1")))
    transcript.apply(.tool(.init(id: "prt_1", name: "read", status: "running", detail: "./app.py", output: "", callID: "c1")))
    transcript.refuse(id: "blocked-per_1", tool: "read", detail: "private/tmp/x/app.py", reason: "outside-project", callID: "c1")
    transcript.apply(.tool(.init(
      id: "prt_1", name: "read", status: "error", detail: "./app.py", output: "", callID: "c1",
      error: "The user rejected permission to use this specific tool call with the following feedback: …")))
    transcript.finish(seconds: 1)
    #expect(transcript.steps.count == 1)
    #expect(transcript.steps[0].kind == .refused && transcript.steps[0].status == .refused)
    #expect(transcript.steps[0].text == "./app.py")
  }

  // Two commands at once: the earlier one approved and running, the next one refused. Only the refused
  // call becomes the refusal; the running one keeps its card and its output.
  @Test func aRefusalNeverLandsOnAnotherCallOfTheSameTool() {
    var transcript = Transcript()
    transcript.apply(.tool(.init(id: "prt_a", name: "bash", status: "running", detail: "make", output: "", callID: "ca")))
    transcript.approved(callID: "ca")
    transcript.apply(.tool(.init(id: "prt_a", name: "bash", status: "running", detail: "make", output: "building", callID: "ca")))
    transcript.refuse(id: "blocked-per_b", tool: "bash", detail: "rm -rf ~", reason: "outside-project", callID: "cb")
    transcript.apply(.tool(.init(id: "prt_b", name: "bash", status: "error", detail: "rm -rf ~", output: "", callID: "cb",
      error: "The user rejected permission to use this specific tool call with the following feedback: …")))
    #expect(transcript.steps.map(\.kind) == [.tool, .refused])
    #expect(transcript.steps[0].status == .running && transcript.steps[0].output == "building")
    #expect(transcript.waitingStep(callID: "ca") == "prt_a")
    #expect(transcript.waitingStep(callID: "cb") == nil)
  }

  @Test func aQuestionShowsOnTheStepItNames() {
    var transcript = Transcript()
    transcript.apply(.tool(.init(id: "prt_1", name: "edit", status: "running", detail: "a.txt", output: "", callID: "c1")))
    transcript.apply(.tool(.init(id: "prt_2", name: "edit", status: "running", detail: "b.txt", output: "", callID: "c2")))
    #expect(transcript.waitingStep(callID: "c1") == "prt_1")
    #expect(transcript.waitingStep(callID: nil) == nil)
    #expect(transcript.waitingStep(callID: "unknown") == nil)
  }

  @Test func aCallTheHarnessRefusesByItsOwnRulesIsBlockedNotFailed() {
    var transcript = Transcript()
    transcript.apply(.tool(.init(
      id: "t", name: "bash", status: "error", detail: "rm -rf ~/Desktop", output: "", callID: "c",
      error: "The user has specified a rule which prevents you from using this specific tool call. …")))
    #expect(transcript.steps[0].status == .refused)
  }

  @Test func hugeOutputIsCutBeforeItIsCleaned() {
    var cleaned = 0
    var transcript = Transcript()
    let huge = String(repeating: "line of build output\n", count: 200_000)
    transcript.apply(.tool(.init(id: "t", name: "bash", status: "running", detail: "make", output: huge, callID: "c"))) {
      cleaned = max(cleaned, $0.count)
      return $0
    }
    #expect(cleaned <= Transcript.outputLimit + 512 || cleaned == "make".count)
    #expect(transcript.steps[0].truncated)
  }

  @Test func outputIsRedactedAndLongOutputKeepsItsTail() {
    var transcript = Transcript()
    let long = String(repeating: "x", count: Transcript.outputLimit + 500) + "\nKEY=sk-abcdefghijklmnop1234 END"
    transcript.apply(.tool(.init(id: "t", name: "bash", status: "completed", detail: "env", output: long, exitCode: 0))) {
      Redaction.clean($0, root: URL(fileURLWithPath: "/work/proj"), label: "<project>")
    }
    let step = transcript.steps[0]
    #expect(step.truncated)
    #expect(step.output.hasSuffix("<secret> END"))
    #expect(!step.output.contains("sk-abcdefghijklmnop1234"))
    #expect(step.output.count <= Transcript.outputLimit + 2)
  }

  @Test func whatIsStillRunningWhenTheTurnEndsIsMarkedStopped() {
    var transcript = Transcript()
    transcript.apply(.tool(.init(id: "t", name: "bash", status: "running", detail: "sleep 100", output: "")))
    transcript.finish(seconds: 3)
    #expect(transcript.steps[0].status == .failed)
    #expect(transcript.steps[0].error == "Stopped when the turn ended.")
    #expect(transcript.usage.seconds == 3)
  }

  @Test func savedMessagesFromBeforeStepsStillLoad() throws {
    let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","role":"assistant","content":"hi"}"#
    let message = try JSONDecoder().decode(ChatMessage.self, from: Data(old.utf8))
    #expect(message.content == "hi" && message.steps == nil)
  }

  @Test func aStepsClockStartsWhenTheUserApprovesNotWhenTheModelAsked() throws {
    var transcript = Transcript()
    let asked = Date(timeIntervalSince1970: 1_000)
    let approved = asked.addingTimeInterval(30)
    transcript.apply(.tool(.init(id: "t", name: "bash", status: "running", detail: "make", output: "", callID: "c", started: asked)))
    transcript.approved(callID: "c", at: approved)
    transcript.apply(.tool(.init(
      id: "t", name: "bash", status: "completed", detail: "make", output: "ok", callID: "c", exitCode: 0, started: asked,
      ended: approved.addingTimeInterval(2))))
    let duration = try #require(transcript.steps[0].duration)
    #expect(abs(duration - 2) < 0.001)
  }

  @Test func secretsAreHiddenButPathsStayForTheUserToSee() {
    let text = "wrote /tmp/x/app.py with key sk-abcdefghijklmnop1234"
    #expect(Redaction.secrets(text) == "wrote /tmp/x/app.py with key <secret>")
    #expect(Redaction.clean(text, root: URL(fileURLWithPath: "/nope"), label: "") == "wrote <path> with key <secret>")
  }
}

/// The approval flow on a real recording: the question names its call, the answer is announced.
@Suite struct ApprovalFlowTests {
  @Test func questionsNameTheirCallAndAnswersAreAnnounced() {
    let events = AgentApprovalFixture.events.compactMap { AgentEventDecoder.decode(Data($0.utf8)) }
    let questions = events.compactMap { if case .permission(let p) = $0 { p } else { nil } }
    let replied = events.compactMap { if case .permissionReplied(let id) = $0 { id } else { nil } }
    #expect(questions.map(\.tool) == ["bash", "edit"])
    #expect(questions.allSatisfy { $0.callID != nil })
    #expect(replied == questions.map(\.id))
  }

  /// Plays the recording the way the app does: allow the command, refuse the edit.
  @Test func anAllowedCommandAndARefusedEditShowAsTwoStepsInPlace() throws {
    var transcript = Transcript()
    var waitingOn: [String?] = []
    for event in AgentApprovalFixture.events.compactMap({ AgentEventDecoder.decode(Data($0.utf8)) }) {
      transcript.apply(event)
      guard case .permission(let question) = event else { continue }
      waitingOn.append(transcript.waitingStep(callID: question.callID))
      if question.tool == "bash" {
        transcript.approved(callID: question.callID)
      } else {
        transcript.refuse(
          id: "blocked-\(question.id)", tool: question.tool, detail: question.detail, reason: "test",
          callID: question.callID)
      }
    }
    // Each question was shown on its own step, which already existed.
    #expect(waitingOn.count == 2 && waitingOn.allSatisfy { $0 != nil })
    // The model also read app.py before editing it: three calls, three steps, the edit refused in place.
    let tools = transcript.steps.filter { $0.kind != .text }
    #expect(tools.map(\.tool) == ["bash", "read", "edit"])
    #expect(tools.map(\.kind) == [.tool, .tool, .refused])
    #expect(tools[0].status == .done && tools[0].output.contains("one") && tools[0].output.contains("two"))
    #expect(tools[2].output == "test" && tools[2].text == "/work/proj/app.py")
  }
}
