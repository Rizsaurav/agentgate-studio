import Foundation
import Testing

@testable import AgentGateCore

@Suite struct ModelMeasurementTests {
  private func profile(_ mac: String = "Apple M2, 8 GB", tps: Double = 40, passed: Int = 5) -> MeasuredProfile {
    MeasuredProfile(mac: mac, measuredAt: Date(timeIntervalSince1970: 1_800_000_000), tokensPerSecond: tps,
                    timeToFirstToken: 0.3, toolChecksPassed: passed, toolChecksTotal: 5)
  }

  @Test func toolCheckUsesTheSuitesBar() {
    #expect(profile(passed: 5).callsTools)
    #expect(profile(passed: 4).callsTools)
    #expect(!profile(passed: 3).callsTools)
    #expect(!MeasuredProfile(mac: "m", measuredAt: Date(), tokensPerSecond: 1, timeToFirstToken: 1, toolChecksPassed: 0, toolChecksTotal: 0).callsTools)
    #expect(profile(tps: 41.6).summary == "42 tokens/s · first word in 300 ms · tools 5/5")
    var slow = profile()
    slow.timeToFirstToken = 2.46
    #expect(slow.summary.contains("first word in 2.5 s"))
    #expect(profile(tps: 4.24).summary.hasPrefix("4.2 tokens/s"))
  }

  @Test func builtInToolCheckIsValidAndMatchesTheFullSuite() throws {
    let check = try ModelMeasurer.toolCheck()
    #expect(check.cases.count == 5)
    // The same cases as in evals/tools, so the quick check and the published scores agree on what is correct.
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let full = try ToolSuite.load(from: repo.appendingPathComponent("evals/tools"))
    for item in check.cases {
      let original = try #require(full.cases.first { $0.id == item.id })
      #expect(original.messages == item.messages && original.expect == item.expect && original.tools == item.tools, "\(item.id) differs")
    }
  }

  @Test func measurementsAreKeptPerMac() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("measure-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ModelStore(root: root)
    try FileManager.default.createDirectory(at: store.folder("m"), withIntermediateDirectories: true)
    #expect(try store.measurement("m", on: "Apple M2, 8 GB") == nil)
    try store.saveMeasurement(profile(tps: 10), for: "m")
    try store.saveMeasurement(profile("Apple M4, 32 GB", tps: 90), for: "m")
    try store.saveMeasurement(profile(tps: 12), for: "m")
    #expect(try store.measurement("m", on: "Apple M2, 8 GB")?.tokensPerSecond == 12)
    #expect(try store.measurement("m", on: "Apple M4, 32 GB")?.tokensPerSecond == 90)
    #expect(try store.measurements("m").count == 2)
  }

  @Test func speedIsReadFromTheStreamAndTheEngineCount() async throws {
    let stream = """
      data: {"choices":[{"delta":{"role":"assistant"}}]}

      data: {"choices":[{"delta":{"content":"The"}}]}

      data: {"choices":[{"delta":{"content":" sea"}}]}

      data: {"choices":[{"delta":{}}],"timings":{"predicted_per_second":37.5}}

      data: [DONE]

      """
    let server = try TestHTTPServer(body: Data(stream.utf8), servedPath: "/v1/chat/completions")
    defer { server.stop() }
    let measurer = ModelMeasurer(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, apiKey: "k", model: "m")
    let (first, perSecond) = try await measurer.speed()
    #expect(first >= 0 && first < 5)
    #expect(perSecond == 37.5)
  }

  @Test func anAnswerWithoutTextIsAnError() async throws {
    let server = try TestHTTPServer(body: Data("data: [DONE]\n\n".utf8), servedPath: "/v1/chat/completions")
    defer { server.stop() }
    let measurer = ModelMeasurer(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, apiKey: "k", model: "m")
    await #expect(throws: MeasureError.self) { _ = try await measurer.speed() }
  }

  // MARK: The advisor uses measurements

  private let catalog = try! Catalog.bundled()
  private let mac = HardwareProfile(
    chip: "Apple M2", architecture: .appleSilicon, memoryBytes: 16 << 30, gpuWorkingSetBytes: 11 << 30,
    gpuCores: 10, performanceCores: 4, efficiencyCores: 4, freeDiskBytes: 500 << 30, osVersion: "15.0")

  private func installed(_ id: String) throws -> InstalledModel {
    let model = try #require(catalog.model(id))
    let file = try #require(model.gguf.files.first)
    return InstalledModel(
      id: id, name: model.name, quant: file.quant, file: file.file, sha256: file.sha256, bytes: file.bytes, backend: .llamaCpp,
      config: RuntimeConfig(context: 16384, gpuLayers: 999, kvCacheType: "q8_0", flashAttention: true, threads: 4),
      readiness: .ready, reason: "", verifiedAt: Date())
  }

  @Test func aModelThatFailedTheToolCheckIsNotOfferedForToolWork() throws {
    let models = [try installed("qwen3-0.6b"), try installed("qwen3-1.7b")]
    let tools = TaskNeeds(tools: true, longContext: false, priority: .balanced, summary: "")
    let failed = ["qwen3-1.7b": profile(passed: 2)]
    #expect(ModelAdvisor.suggest(catalog, for: mac, installed: models, needs: tools, limit: 20).contains { $0.id == "qwen3-1.7b" })
    #expect(!ModelAdvisor.suggest(catalog, for: mac, installed: models, needs: tools, measured: failed, limit: 20).contains { $0.id == "qwen3-1.7b" })
    let chat = TaskNeeds(tools: false, longContext: false, priority: .balanced, summary: "")
    let offered = try #require(ModelAdvisor.suggest(catalog, for: mac, installed: models, needs: chat, measured: failed, limit: 20).first { $0.id == "qwen3-1.7b" })
    #expect(offered.reasons.contains { $0.hasPrefix("Chat only") })
  }

  @Test func measuredSpeedReplacesTheSizeEstimate() throws {
    let models = [try installed("qwen3-0.6b"), try installed("qwen3-1.7b")]
    let speed = TaskNeeds(tools: false, longContext: false, priority: .speed, summary: "")
    func rank(_ measured: [String: MeasuredProfile]) -> [String] {
      ModelAdvisor.suggest(catalog, for: mac, installed: models, needs: speed, measured: measured, limit: 20)
        .filter(\.installed).map(\.id)
    }
    // By size, the smaller model is the faster one.
    #expect(rank([:]) == ["qwen3-0.6b", "qwen3-1.7b"])
    // Measured otherwise (say the small one was measured while the Mac was busy), the measurement wins.
    #expect(rank(["qwen3-0.6b": profile(tps: 5), "qwen3-1.7b": profile(tps: 60)]) == ["qwen3-1.7b", "qwen3-0.6b"])
  }
}

/// Measures a real model on the bundled engine. Set AGENTGATE_MEASURE_GGUF to a Qwen3 0.6B Q8_0 file and
/// AGENTGATE_LLAMA_DIR to the engine; skipped otherwise.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AGENTGATE_MEASURE_GGUF"] != nil))
struct ModelMeasurementLiveTests {
  @Test func measuresARealModel() async throws {
    let file = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AGENTGATE_MEASURE_GGUF"]!)
    let config = RuntimeConfig(context: 8192, gpuLayers: 999, kvCacheType: "q8_0", flashAttention: true, threads: 4)
    let runtime = try await LlamaRuntime.start(model: file, alias: "qwen3-0.6b", config: config)
    defer { runtime.stop() }
    let measured = try await ModelMeasurer(baseURL: runtime.baseURL, apiKey: runtime.apiKey, model: runtime.alias).measure(on: "test")
    print("measured: \(measured.summary)")
    #expect(measured.tokensPerSecond > 1)
    #expect(measured.timeToFirstToken > 0 && measured.timeToFirstToken < 30)
    #expect(measured.toolChecksTotal == 5)
  }
}
