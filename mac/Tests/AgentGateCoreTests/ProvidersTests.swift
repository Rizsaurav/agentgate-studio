import Foundation
import Testing

@testable import AgentGateCore

@Suite struct ProvidersTests {
  @Test func pastedKeysAreRecognised() {
    #expect(Providers.candidates(for: "sk-or-v1-abc").map(\.id) == ["openrouter"])
    #expect(Providers.candidates(for: " sk-ant-api03-xyz ").map(\.id) == ["anthropic"])
    #expect(Providers.candidates(for: "AIzaSyExample").map(\.id) == ["gemini"])
    #expect(Providers.candidates(for: "gsk_123").map(\.id) == ["groq"])
    #expect(Providers.candidates(for: "sk-proj-abc").map(\.id) == ["openai"])
    // A plain sk- key could be OpenAI or DeepSeek: the user picks.
    #expect(Set(Providers.candidates(for: "sk-1234").map(\.id)) == ["openai", "deepseek"])
    #expect(Providers.candidates(for: "hello").isEmpty)
  }

  @Test func theOpenRouterKeyIsTheBuiltInAgentsKey() {
    #expect(Providers.openRouter.keyAccount == AgentProfile.builtIn.keyAccount)
  }

  @Test func everyProviderUsesHTTPSAndHasAKeysPage() {
    for p in Providers.all {
      #expect(p.baseURL.hasPrefix("https://") && p.keysPage.hasPrefix("https://"), "\(p.id)")
    }
    #expect(Set(Providers.all.map(\.keyAccount)).count == Providers.all.count)
  }

  @Test func verifyMapsStatusCodes() async throws {
    for (status, expected) in [(401, Providers.Verdict.rejected), (403, .rejected)] {
      let server = try TestHTTPServer(body: Data(), fault: .answer(status: status), servedPath: "/models")
      defer { server.stop() }
      let p = Provider(id: "t", name: "Test", baseURL: "http://x", keyAccount: "t", prefixes: [], check: .bearer(server.url("/models").absoluteString), keysPage: "https://x")
      #expect(await Providers.verify(p, key: "k") == expected)
    }
    let ok = try TestHTTPServer(body: Data("{}".utf8), servedPath: "/models")
    defer { ok.stop() }
    let p = Provider(id: "t", name: "Test", baseURL: "http://x", keyAccount: "t", prefixes: [], check: .bearer(ok.url("/models").absoluteString), keysPage: "https://x")
    #expect(await Providers.verify(p, key: "k") == .valid)
  }
}
