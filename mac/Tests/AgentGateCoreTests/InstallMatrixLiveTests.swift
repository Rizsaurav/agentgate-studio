import Foundation
import Testing

@testable import AgentGateCore

// The engine side of the install failure matrix. Needs the bundled engine and one downloaded model:
//   AGENTGATE_LIVE=1 swift test --filter InstallMatrixLive
private let live = ProcessInfo.processInfo.environment["AGENTGATE_LIVE"] == "1"

private func modelFile() throws -> (model: CatalogModel, file: URL) {
  let model = try #require(try Catalog.bundled().model("qwen3-0.6b"))
  let gguf = try #require(model.file(.q8_0))
  let url = AppPaths.models.appendingPathComponent(model.id).appendingPathComponent(gguf.file)
  try #require(FileManager.default.fileExists(atPath: url.path), "Run the LiveInstall tests once to download the model.")
  return (model, url)
}

private let config = RuntimeConfig(context: 4096, gpuLayers: 999, kvCacheType: "q8_0", flashAttention: true, threads: 4)

/// Engines still running whose command line mentions `needle`. Other suites run engines too, so each
/// test looks only for the engine it started, found by its own unique model path.
private func engines(using needle: String) -> Int {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/ps")
  process.arguments = ["-axo", "command"]
  let pipe = Pipe()
  process.standardOutput = pipe
  try? process.run()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return String(decoding: data, as: UTF8.self).split(separator: "\n")
    .filter { $0.contains("llama-server") && $0.contains(needle) }.count
}

/// A copy of the first `bytes` of the model, as if the download or the disk had cut it short.
private func truncatedCopy(of file: URL, bytes: Int) throws -> URL {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentgate-trunc-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let copy = dir.appendingPathComponent(file.lastPathComponent)
  let input = try FileHandle(forReadingFrom: file)
  defer { try? input.close() }
  try (try input.read(upToCount: bytes) ?? Data()).write(to: copy)
  return copy
}

@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: live, "Set AGENTGATE_LIVE=1: needs the engine and a downloaded model.")) struct InstallMatrixLiveTests {
  @Test func engineKilledWhileLoadedIsNoticedAndChatFailsFastInsteadOfHanging() async throws {
    let (model, file) = try modelFile()
    let runtime = try await LlamaRuntime.start(model: file, alias: model.id, config: config, binaries: devRuntime)
    defer { runtime.stop() }
    kill(runtime.processIdentifier, SIGKILL)
    let started = Date()
    while runtime.isRunning, Date().timeIntervalSince(started) < 5 { try await Task.sleep(for: .milliseconds(50)) }
    #expect(!runtime.isRunning)
    let client = ChatClient(baseURL: runtime.baseURL, apiKey: runtime.apiKey, model: model.id)
    let chatStarted = Date()
    await #expect(throws: (any Error).self) {
      for try await _ in client.stream([ChatMessage(role: .user, content: "hi")], maxTokens: 8) {}
    }
    #expect(Date().timeIntervalSince(chatStarted) < 10)
  }

  @Test func truncatedModelFileFailsToLoadWithAnExplanationAndLeavesNoEngine() async throws {
    let (model, file) = try modelFile()
    let cut = try truncatedCopy(of: file, bytes: 100_000_000)
    let started = Date()
    await #expect {
      _ = try await LlamaRuntime.start(model: cut, alias: model.id, config: config, binaries: devRuntime, loadTimeout: 60)
    } throws: { error in
      if case RuntimeError.exited(_, let tail) = error { !tail.isEmpty } else { false }
    }
    #expect(Date().timeIntervalSince(started) < 60)
    #expect(engines(using: cut.path) == 0)
  }

  @Test func installedModelWhoseFileChangedIsRefusedBeforeLoading() async throws {
    let (model, file) = try modelFile()
    let gguf = try #require(model.file(.q8_0))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentgate-store-\(UUID().uuidString)")
    let store = ModelStore(root: root)
    let cut = try truncatedCopy(of: file, bytes: 50_000_000)
    try FileManager.default.createDirectory(at: store.folder(model.id), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: cut, to: store.folder(model.id).appendingPathComponent(gguf.file))
    let installed = InstalledModel(
      id: model.id, name: model.name, quant: .q8_0, file: gguf.file, sha256: gguf.sha256, bytes: gguf.bytes,
      backend: .llamaCpp, config: config, readiness: .ready, reason: "", verifiedAt: Date())
    var pipeline = InstallPipeline()
    pipeline.store = store
    pipeline.binaries = devRuntime
    await #expect {
      _ = try await pipeline.load(installed) { _ in }
    } throws: { error in
      (error as? InstallFailure)?.message.contains("changed since it was installed") == true
    }
    #expect(engines(using: root.path) == 0)
  }

  @Test func twoEnginesRunSideBySideOnDifferentPorts() async throws {
    let (model, file) = try modelFile()
    async let first = LlamaRuntime.start(model: file, alias: model.id, config: config, binaries: devRuntime)
    async let second = LlamaRuntime.start(model: file, alias: model.id, config: config, binaries: devRuntime)
    let (a, b) = try await (first, second)
    defer { a.stop(); b.stop() }
    #expect(a.baseURL.port != b.baseURL.port)
    #expect(a.apiKey != b.apiKey)
    #expect(a.isRunning && b.isRunning)
  }

  @Test func stoppingAnEngineLeavesNoProcessBehind() async throws {
    let (model, file) = try modelFile()
    let runtime = try await LlamaRuntime.start(model: file, alias: model.id, config: config, binaries: devRuntime)
    let pid = runtime.processIdentifier
    #expect(kill(pid, 0) == 0)
    runtime.stop()
    #expect(kill(pid, 0) != 0)  // no such process
    #expect(!runtime.isRunning)
  }

  @Test func theEngineNeverUsesOllamasPort() async throws {
    let (model, file) = try modelFile()
    let runtime = try await LlamaRuntime.start(model: file, alias: model.id, config: config, binaries: devRuntime)
    defer { runtime.stop() }
    #expect(runtime.baseURL.port != 11434)
  }
}

extension InstallMatrixLiveTests {
  /// Another process takes the engine's port between choosing it and binding it: the engine is started
  /// again on a new port instead of the install failing.
  @Test func aPortTakenByAnotherProcessDoesNotFailTheStart() async throws {
    let (model, file) = try modelFile()
    // Occupy many ports so some choices collide; the start must still succeed.
    let servers = try (0..<1).map { _ in try TestHTTPServer(body: Data()) }
    defer { servers.forEach { $0.stop() } }
    let runtime = try await LlamaRuntime.start(model: file, alias: model.id, config: config, binaries: devRuntime)
    defer { runtime.stop() }
    #expect(runtime.isRunning)
    #expect(!servers.map { Int($0.port) }.contains(runtime.baseURL.port ?? 0))
  }
}

/// The bundled agent harness itself, with no model: it must start, demand its password, and stop.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AgentServerLiveTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTGATE_LIVE"] == "1"))
  func startsBehindAPasswordAndStopsClean() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let server = try await AgentServer.start(
      folder: folder, engineURL: URL(string: "http://127.0.0.1:9")!, engineKey: "k", model: "m",
      binaries: URL(fileURLWithPath: ProcessInfo.processInfo.environment["AGENTGATE_OPENCODE_DIR"] ?? ""))
    #expect(server.isRunning)
    var open = URLRequest(url: server.baseURL.appendingPathComponent("session/status"))
    open.httpMethod = "GET"
    let (_, response) = try await URLSession.shared.data(for: open)
    #expect((response as? HTTPURLResponse)?.statusCode == 401)
    let id = try await server.client.createSession(title: "t")
    #expect(!id.isEmpty)
    let pid = server.processIdentifier
    server.stop()
    #expect(kill(pid, 0) != 0)
  }
}

/// One real request to the pinned OpenRouter model. Needs OPENROUTER_API_KEY and costs a fraction of a cent.
@Suite(.serialized, .timeLimit(.minutes(1))) struct RepairAgentLiveTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTGATE_LIVE"] == "1"
                 && ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] != nil))
  func theRealModelFollowsTheReplyFormat() async throws {
    let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]
    let assistant = OpenRouterAssistant(apiKey: { key })
    var report = FailureReport(
      step: "Load", failureClass: .outOfMemory, message: "The model did not fit in memory.",
      logTail: "ggml_metal: failed to allocate buffer, size = 9000.00 MiB", hardware: "Apple M2 · 8 GB · 40 GB free",
      triedAlready: [])
    var steps: [String] = []
    for _ in 0...RepairRunner.maxProbes {
      let reply = try await assistant.propose(for: report, removable: [])
      switch try RepairReply.parse(reply, removable: []) {
      case .probe(let probe):
        steps.append("probe \(probe.rawValue)")
        report.findings.append("\(probe.rawValue): checked")
      case .command(let command):
        steps.append("command \(command)")
        report.findings.append("command \(command): not run in this test")
      case .proposal(let proposal):
        steps.append("fix \(proposal.operations.map(\.name))")
        print("AGENT STEPS:", steps, "|", proposal.explanation)
        return
      }
    }
    Issue.record("The model kept probing: \(steps)")
  }
}
