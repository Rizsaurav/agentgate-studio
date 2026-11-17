import Foundation
import Testing

@testable import AgentGateCore

@Suite struct CapabilityProfileTests {
  private let catalog = try! Catalog.bundled()

  private func profile(thinking: Bool? = false, sampler: Bool = true, variant: CapabilityProfile.PromptVariant = .compact) -> CapabilityProfile {
    CapabilityProfile(
      toolCallFormat: "hermes", thinking: thinking,
      sampler: sampler ? .init(temperature: 0.6, topP: 0.8, passRate: 0.8, measured: "2026-11-17", engine: "llama.cpp b1") : nil,
      promptVariant: variant, knownIssues: ["Rarely tries again after a tool returns an error."])
  }

  @Test func everyCatalogModelHasAProfileAndToolModelsHaveAFormat() {
    for model in catalog.models {
      #expect(model.toolCalling == (model.profile.toolCallFormat != "none"), "\(model.id)")
    }
    // Derived from the chat templates, not typed in.
    #expect(catalog.model("qwen3-1.7b")?.profile.thinking == false)
    #expect(catalog.model("qwen3-4b-2507")?.profile.thinking == nil)
    #expect(catalog.model("llama-3.2-3b")?.profile.toolCallFormat == "llama3-json")
  }

  @Test func aMalformedProfileRejectsTheCatalog() throws {
    let url = try #require(Bundle.module.url(forResource: "catalog", withExtension: "json"))
    let good = try String(contentsOf: url, encoding: .utf8)
    for (old, new) in [(#""toolCallFormat": "hermes""#, #""toolCallFormat": "xml""#),
                       (#""toolCallFormat": "llama3-json""#, #""toolCallFormat": "none""#)] {
      #expect(good.contains(old))
      #expect(throws: CatalogError.self) { try Catalog.decode(Data(good.replacingOccurrences(of: old, with: new).utf8)) }
    }
    var json = try #require(try JSONSerialization.jsonObject(with: Data(good.utf8)) as? [String: Any])
    var models = try #require(json["models"] as? [[String: Any]])
    models[0]["profile"] = nil
    json["models"] = models
    #expect(throws: CatalogError.self) { try Catalog.decode(try JSONSerialization.data(withJSONObject: json)) }
  }

  @Test func theProfileFillsInWhatARequestLeavesOpenAndNeverOverrides() {
    var open: [String: Any] = ["model": "m"]
    profile().apply(to: &open)
    #expect(open["temperature"] as? Double == 0.6)
    #expect(open["top_p"] as? Double == 0.8)
    #expect((open["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == false)

    var pinned: [String: Any] = ["model": "m", "temperature": 0.0, "chat_template_kwargs": ["enable_thinking": true]]
    profile().apply(to: &pinned)
    #expect(pinned["temperature"] as? Double == 0.0)
    #expect((pinned["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == true)

    var noSwitch: [String: Any] = [:]
    profile(thinking: nil, sampler: false).apply(to: &noSwitch)
    #expect(noSwitch.isEmpty)
  }

  @Test func theGatewaySendsTheProfileToTheEngine() async throws {
    let engine = try TestHTTPServer(body: Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8), servedPath: "/v1/chat/completions")
    defer { engine.stop() }
    let applied = profile()
    let gateway = try Gateway(resolve: { _ in .local(baseURL: URL(string: "http://127.0.0.1:\(engine.port)")!, key: "k", model: "m", profile: applied) })
    defer { gateway.stop() }
    var request = URLRequest(url: gateway.baseURL.appendingPathComponent("v1/chat/completions"))
    request.httpMethod = "POST"
    request.setValue("Bearer \(gateway.key)", forHTTPHeaderField: "Authorization")
    request.httpBody = Data(#"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#.utf8)
    _ = try await URLSession.shared.data(for: request)
    let raw = engine.lastRequest
    let body = try #require(raw.range(of: "\r\n\r\n").map { String(raw[$0.upperBound...]) })
    let sent = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    #expect((sent["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == false)
    #expect(sent["temperature"] as? Double == 0.6)
    #expect(sent["top_p"] as? Double == 0.8)
  }

  @Test func theHarnessGetsTheSamplerAndTheCompactInstructions() throws {
    func agent(_ p: CapabilityProfile?) throws -> [String: Any]? {
      let text = try AgentServer.config(engineURL: URL(string: "http://127.0.0.1:1")!, engineKey: "k", model: "m", context: 8192, profile: p)
      let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
      return (json?["agent"] as? [String: Any])?["build"] as? [String: Any]
    }
    let compact = try #require(try agent(profile()))
    #expect(compact["temperature"] as? Double == 0.6)
    #expect(compact["top_p"] as? Double == 0.8)
    #expect(compact["prompt"] as? String == CapabilityProfile.compactPrompt)
    // A large model keeps the harness's own instructions; a model never measured keeps the engine's sampler.
    #expect(try agent(profile(sampler: false, variant: .full)) == nil)
    #expect(try agent(nil) == nil)
  }
}
