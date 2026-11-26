import Foundation

/// A cloud model provider the user can add a key for. Keys live in the Keychain and are never shown again.
public struct Provider: Sendable, Identifiable, Equatable {
  public enum Check: Sendable, Equatable {
    /// GET <url> with `Authorization: Bearer <key>`.
    case bearer(String)
    /// Anthropic's own headers.
    case anthropic(String)
  }

  public var id: String
  public var name: String
  /// The OpenAI-compatible address models are called at.
  public var baseURL: String
  public var keyAccount: String
  /// How a pasted key is recognised. An empty list means the provider cannot be told apart by its key.
  public var prefixes: [String]
  /// A free request that only succeeds with a valid key.
  public var check: Check
  /// Where to get a key.
  public var keysPage: String

  public var keychain: Keychain { Keychain(account: keyAccount) }
}

public enum Providers {
  /// The account matches the built-in agent's, so a key added here also turns the agent on.
  public static let openRouter = Provider(
    id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", keyAccount: "openrouter",
    prefixes: ["sk-or-"], check: .bearer("https://openrouter.ai/api/v1/auth/key"), keysPage: "https://openrouter.ai/keys")

  public static let all: [Provider] = [
    openRouter,
    Provider(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", keyAccount: "provider-openai",
             prefixes: ["sk-proj-", "sk-svcacct-", "sk-admin-"], check: .bearer("https://api.openai.com/v1/models"),
             keysPage: "https://platform.openai.com/api-keys"),
    Provider(id: "anthropic", name: "Anthropic", baseURL: "https://api.anthropic.com/v1", keyAccount: "provider-anthropic",
             prefixes: ["sk-ant-"], check: .anthropic("https://api.anthropic.com/v1/models"),
             keysPage: "https://console.anthropic.com/settings/keys"),
    Provider(id: "gemini", name: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
             keyAccount: "provider-gemini", prefixes: ["AIza"],
             check: .bearer("https://generativelanguage.googleapis.com/v1beta/openai/models"),
             keysPage: "https://aistudio.google.com/apikey"),
    Provider(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com", keyAccount: "provider-deepseek",
             prefixes: [], check: .bearer("https://api.deepseek.com/models"), keysPage: "https://platform.deepseek.com/api_keys"),
    Provider(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1", keyAccount: "provider-groq",
             prefixes: ["gsk_"], check: .bearer("https://api.groq.com/openai/v1/models"), keysPage: "https://console.groq.com/keys"),
  ]

  /// The providers a pasted key could belong to. A plain `sk-` key could be OpenAI or DeepSeek, so both are returned.
  public static func candidates(for key: String) -> [Provider] {
    let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    if let exact = all.first(where: { p in p.prefixes.contains { key.hasPrefix($0) } }) { return [exact] }
    if key.hasPrefix("sk-") { return all.filter { $0.id == "openai" || $0.id == "deepseek" } }
    return []
  }

  public enum Verdict: Sendable, Equatable {
    case valid
    case rejected
    case unreachable(String)
  }

  /// Checks a key with a free request. Nothing is saved here.
  public static func verify(_ provider: Provider, key: String, session: URLSession = .shared) async -> Verdict {
    let url: String
    var request: URLRequest
    switch provider.check {
    case .bearer(let address):
      url = address
      request = URLRequest(url: URL(string: url)!, timeoutInterval: 15)
      request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    case .anthropic(let address):
      url = address
      request = URLRequest(url: URL(string: url)!, timeoutInterval: 15)
      request.setValue(key, forHTTPHeaderField: "x-api-key")
      request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    }
    do {
      let (_, response) = try await session.data(for: request)
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      if (200..<300).contains(code) { return .valid }
      if code == 401 || code == 403 { return .rejected }
      return .unreachable("\(provider.name) answered HTTP \(code).")
    } catch {
      return .unreachable("\(provider.name) could not be reached: \(error.localizedDescription)")
    }
  }
}
