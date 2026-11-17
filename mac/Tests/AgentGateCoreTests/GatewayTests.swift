import Foundation
import Testing

@testable import AgentGateCore

@Suite struct GatewayTests {
  private let reply = #"{"choices":[{"message":{"role":"assistant","content":"hi"}}]}"#

  private func provider(_ server: TestHTTPServer) -> Provider {
    Provider(id: "testcloud", name: "Test Cloud", baseURL: "http://127.0.0.1:\(server.port)/v1", keyAccount: "unused",
             prefixes: [], check: .bearer("http://127.0.0.1/"), keysPage: "")
  }

  private func post(_ gateway: Gateway, model: String, key: String? = nil, extra: String = "") async throws -> (Int, String) {
    var request = URLRequest(url: gateway.baseURL.appendingPathComponent("v1/chat/completions"), timeoutInterval: 10)
    request.httpMethod = "POST"
    request.setValue("Bearer \(key ?? gateway.key)", forHTTPHeaderField: "Authorization")
    request.httpBody = Data(#"{"model":"\#(model)","messages":[{"role":"user","content":"hello"}]\#(extra)}"#.utf8)
    let (data, response) = try await URLSession.shared.data(for: request)
    return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
  }

  @Test func modelIdsNameLocalOrCloudModels() {
    #expect(ModelID.parseCloud("qwen3-1.7b") == nil)
    #expect(ModelID.parseCloud("openrouter/deepseek/deepseek-chat").map { "\($0.0.id) \($0.1)" } == "openrouter deepseek/deepseek-chat")
    #expect(ModelID.parseCloud("nobody/model") == nil)
    #expect(ModelID.cloud(Providers.openRouter, "x/y") == "openrouter/x/y")
  }

  @Test func onlyHolderOfTheLaunchKeyCanUseIt() async throws {
    let gateway = try Gateway(resolve: { _ in nil })
    defer { gateway.stop() }
    #expect(try await post(gateway, model: "m", key: "wrong").0 == 401)
    #expect(try await post(gateway, model: "m", key: "").0 == 401)
    #expect(try await post(gateway, model: "missing").0 == 404)
  }

  @Test func localModelsGoToTheEngineWithTheEngineKey() async throws {
    let engine = try TestHTTPServer(body: Data(reply.utf8), servedPath: "/v1/chat/completions")
    defer { engine.stop() }
    let gateway = try Gateway(resolve: { id in
      id == "qwen3-1.7b" ? .local(baseURL: URL(string: "http://127.0.0.1:\(engine.port)")!, key: "engine-key", model: "qwen3-1.7b") : nil
    })
    defer { gateway.stop() }
    let (status, body) = try await post(gateway, model: "qwen3-1.7b", extra: #","tools":[{"type":"function","function":{"name":"f"}}]"#)
    #expect(status == 200 && body == reply)
    #expect(engine.lastRequest.contains("Bearer engine-key"))
    #expect(engine.lastRequest.contains(#""tools""#))
    #expect(!engine.lastRequest.contains(gateway.key))
  }

  @Test func cloudModelsGoToTheirProviderWithTheUsersKeyOnly() async throws {
    let cloud = try TestHTTPServer(body: Data(reply.utf8), servedPath: "/v1/chat/completions")
    defer { cloud.stop() }
    let provider = provider(cloud)
    let gateway = try Gateway(resolve: { id in id == "testcloud/big-model" ? .cloud(provider, model: "big-model") : nil },
                              providerKey: { _ in "sk-user-secret" })
    defer { gateway.stop() }
    let (status, body) = try await post(gateway, model: "testcloud/big-model", extra: #","chat_template_kwargs":{"enable_thinking":false}"#)
    #expect(status == 200 && body == reply)
    #expect(cloud.lastRequest.contains("Bearer sk-user-secret"))
    #expect(cloud.lastRequest.contains(#""model":"big-model""#))
    // Engine-only options are not sent to a provider.
    #expect(!cloud.lastRequest.contains("chat_template_kwargs"))
    #expect(!body.contains("sk-user-secret"))
  }

  @Test func aMissingOrRejectedKeyGivesAPlainErrorWithoutTheProvidersBody() async throws {
    let cloud = try TestHTTPServer(body: Data(), fault: .answer(status: 401), servedPath: "/v1/chat/completions")
    defer { cloud.stop() }
    let provider = provider(cloud)
    let none = try Gateway(resolve: { _ in .cloud(provider, model: "m") }, providerKey: { _ in nil })
    defer { none.stop() }
    let (missing, missingBody) = try await post(none, model: "testcloud/m")
    #expect(missing == 401 && missingBody.contains("There is no Test Cloud key"))

    let revoked = try Gateway(resolve: { _ in .cloud(provider, model: "m") }, providerKey: { _ in "sk-revoked-123456789" })
    defer { revoked.stop() }
    let (status, body) = try await post(revoked, model: "testcloud/m")
    #expect(status == 401)
    #expect(body.contains("rejected the key"))
    #expect(!body.contains("sk-revoked"))
  }

  @Test func streamedAnswersPassThroughUnchanged() async throws {
    let stream = (1...40).map { #"data: {"choices":[{"delta":{"content":"word\#($0) "}}]}"# + "\n\n" }.joined() + "data: [DONE]\n\n"
    let engine = try TestHTTPServer(body: Data(stream.utf8), servedPath: "/v1/chat/completions")
    defer { engine.stop() }
    let gateway = try Gateway(resolve: { _ in .local(baseURL: URL(string: "http://127.0.0.1:\(engine.port)")!, key: "k", model: "m") })
    defer { gateway.stop() }
    let (status, body) = try await post(gateway, model: "m", extra: #","stream":true"#)
    #expect(status == 200 && body == stream)
  }

  @Test func aClientThatHangsUpCancelsTheUpstreamRequest() async throws {
    // The engine sends a little and then goes silent, like a long generation.
    let engine = try TestHTTPServer(body: Data(String(repeating: "x", count: 1000).utf8), fault: .stallFirst(after: 10), servedPath: "/v1/chat/completions")
    defer { engine.stop() }
    let gateway = try Gateway(resolve: { _ in .local(baseURL: URL(string: "http://127.0.0.1:\(engine.port)")!, key: "k", model: "m") })
    defer { gateway.stop() }
    let client = Task { try await post(gateway, model: "m") }
    for _ in 0..<100 where gateway.activeForwards == 0 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(gateway.activeForwards == 1)
    client.cancel()
    _ = try? await client.value
    for _ in 0..<150 where gateway.activeForwards > 0 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(gateway.activeForwards == 0)
  }
}

/// The real harness through the gateway to the real engine: the path every session takes.
/// Needs AGENTGATE_LLAMA_DIR, AGENTGATE_OPENCODE_DIR and AGENTGATE_MEASURE_GGUF; skipped otherwise.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AGENTGATE_LIVE_GATEWAY"] == "1"))
struct GatewayLiveTests {
  @Test func aHarnessSessionRunsThroughTheGateway() async throws {
    let file = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AGENTGATE_MEASURE_GGUF"]!)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gateway-live-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try "The launch code word is PELICAN.\n".write(to: folder.appendingPathComponent("NOTES.md"), atomically: true, encoding: .utf8)
    let runtime = try await LlamaRuntime.start(
      model: file, alias: "qwen3-0.6b", config: RuntimeConfig(context: 16384, gpuLayers: 999, kvCacheType: "q8_0", flashAttention: true, threads: 4))
    defer { runtime.stop() }
    let gateway = try Gateway(resolve: { id in id == "qwen3-0.6b" ? .local(baseURL: runtime.baseURL, key: runtime.apiKey, model: id) : nil })
    defer { gateway.stop() }
    let server = try await AgentServer.start(folder: folder, engineURL: gateway.baseURL, engineKey: gateway.key, model: "qwen3-0.6b", context: 16384)
    defer { server.stop() }
    let client = server.client
    let session = try await client.createSession(title: "gateway")
    let events = Task { () throws -> (tools: [String], text: Bool) in
      var tools: [String] = []
      var text = false
      for try await event in client.events() {
        switch event {
        case .permission(let p): try await client.reply(permission: p.id, allow: ToolCallCheck.check(p, folder: folder) == nil)
        case .tool(let t) where t.status == "completed": tools.append(t.name)
        case .text(_, _, let body) where !body.isEmpty: text = true
        case .idle: return (tools, text)
        case .failed(let message): throw AgentError.startTimedOut(message)
        default: break
        }
      }
      return (tools, text)
    }
    let timer = Task { try await Task.sleep(for: .seconds(300)); events.cancel() }
    try await Task.sleep(nanoseconds: 500_000_000)
    try await client.prompt(session: session, text: "Read NOTES.md and tell me the launch code word.", model: "qwen3-0.6b")
    let (tools, text) = try await events.value
    timer.cancel()
    print("through the gateway: tools \(tools), answered \(text)")
    #expect(text || !tools.isEmpty, "the harness got nothing back through the gateway")
    #expect(gateway.activeForwards == 0)
  }
}
