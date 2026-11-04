import Foundation
import Testing

@testable import AgentGateCore

/// The engine fetched by scripts/fetch_runtime.sh, relative to this package.
let devRuntime = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("dist/runtime/llama")

private let live = ProcessInfo.processInfo.environment["AGENTGATE_LIVE"] == "1"

@Suite(.serialized, .enabled(if: live, "Set AGENTGATE_LIVE=1: downloads a real model."))
struct LiveInstallTests {
  @Test func downloadLoadAndVerifyARealModel() async throws {
    let catalog = try Catalog.bundled()
    let model = try #require(catalog.model("qwen3-0.6b"))
    let file = try #require(model.file(.q8_0))
    let destination = AppPaths.models.appendingPathComponent(model.id).appendingPathComponent(file.file)
    if !FileManager.default.fileExists(atPath: destination.path) {
      let url = URL(string: "https://huggingface.co/\(model.gguf.repo)/resolve/main/\(file.file)")!
      try await Downloader().download(from: url, to: destination, bytes: file.bytes, sha256: file.sha256) { _ in }
    }
    let profile = try HardwareProbe.current(modelsDirectory: AppPaths.models)
    let plan = try #require(ModelPlanner.plan(model, for: profile).plan)
    let runtime = try await LlamaRuntime.start(
      model: destination, alias: model.id, config: .for(plan, profile: profile), binaries: devRuntime)
    defer { runtime.stop() }
    let readiness = try await ModelVerifier().verify(baseURL: runtime.baseURL, apiKey: runtime.apiKey, model: model.id)
    #expect(readiness == .ready)

    // The engine refuses requests without the per-launch key.
    var request = URLRequest(url: runtime.baseURL.appendingPathComponent("v1/models"))
    request.httpMethod = "GET"
    let (_, response) = try await URLSession.shared.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 401)
  }

  @Test func pipelineReportsEveryStepInOrder() async throws {
    let model = try #require(try Catalog.bundled().model("qwen3-0.6b"))
    var pipeline = InstallPipeline()
    pipeline.binaries = devRuntime
    let steps = Steps()
    let (installed, runtime) = try await pipeline.install(model) { steps.record($0.step) }
    defer { runtime.stop() }
    #expect(steps.unique == InstallStep.allCases)
    #expect(installed.readiness == .ready)
    #expect(try ModelStore().load(model.id) == installed)
  }

  @Test func outOfMemoryIsDetected() async throws {
    let model = try #require(try Catalog.bundled().model("qwen3-0.6b"))
    let path = AppPaths.models.appendingPathComponent(model.id).appendingPathComponent(model.file(.q8_0)!.file)
    try #require(FileManager.default.fileExists(atPath: path.path))
    // A context far beyond any Mac's memory makes the KV cache allocation fail.
    let config = RuntimeConfig(context: 40_960 * 64, gpuLayers: 999, kvCacheType: "f16", flashAttention: true, threads: 4)
    await #expect(throws: RuntimeError.outOfMemory) {
      _ = try await LlamaRuntime.start(model: path, alias: "oom", config: config, binaries: devRuntime)
    }
  }
}

private final class Steps: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [InstallStep] = []
  func record(_ step: InstallStep) { lock.withLock { if values.last != step { values.append(step) } } }
  var unique: [InstallStep] { lock.withLock { values } }
}
