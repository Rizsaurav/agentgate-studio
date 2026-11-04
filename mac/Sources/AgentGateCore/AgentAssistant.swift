import Foundation

/// The supervising agent, running on any OpenAI-compatible provider the user chose. Every agent gets the
/// same playbook and the same toolbox; only the provider, model and key differ.
public struct AgentAssistant: RepairAssistant {
  public var profile: AgentProfile
  /// Room for the model's own reasoning as well as the short answer.
  static let maxReplyTokens = 1500

  public enum Failure: Error, Equatable, CustomStringConvertible {
    case noKey, http(Int), malformed
    public var description: String {
      switch self {
      case .noKey: "No key is saved for this agent."
      case .http(let code): "The agent's provider answered with HTTP \(code)."
      case .malformed: "The agent's provider sent a reply that could not be read."
      }
    }
  }

  public var baseURL: URL
  public var apiKey: @Sendable () throws -> String?
  public var session: URLSession

  public init(
    profile: AgentProfile = .builtIn, baseURL: URL? = nil,
    apiKey: (@Sendable () throws -> String?)? = nil, session: URLSession = .shared
  ) {
    self.profile = profile
    self.baseURL = baseURL ?? URL(string: profile.baseURL)!
    self.apiKey = apiKey ?? {
      // OPENROUTER_API_KEY is for automated tests only; the app keeps keys in the Keychain.
      if profile.isBuiltIn, let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] { return key }
      return try profile.keychain.read()
    }
    self.session = session
  }

  /// The request body, built from the redacted report only.
  func requestBody(_ report: FailureReport, removable: [String]) throws -> Data {
    let reportJSON = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
    var body: [String: Any] = [
      "model": profile.model, "temperature": 0, "max_tokens": Self.maxReplyTokens,
      "response_format": ["type": "json_object"],
      "messages": [
        ["role": "system", "content": RepairPlaybook.instructions],
        ["role": "user", "content": "Failure report:\n\(reportJSON)\nRemovable model ids: \(removable)"],
      ],
    ]
    // OpenRouter's own option to keep a reasoning model's thinking short.
    if profile.isOpenRouter { body["reasoning"] = ["effort": "low"] }
    return try JSONSerialization.data(withJSONObject: body)
  }

  public func propose(for report: FailureReport, removable: [String]) async throws -> String {
    guard let key = try apiKey(), !key.isEmpty else { throw Failure.noKey }
    var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"), timeoutInterval: 20)
    request.httpMethod = "POST"
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try requestBody(report, removable: removable)
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw Failure.malformed }
    guard http.statusCode == 200 else { throw Failure.http(http.statusCode) }
    struct Reply: Decodable {
      struct Choice: Decodable { struct Message: Decodable { var content: String? }; var message: Message }
      var choices: [Choice]
    }
    guard let content = try? JSONDecoder().decode(Reply.self, from: data).choices.first?.message.content else {
      throw Failure.malformed
    }
    return content
  }

  /// Looks a question up with OpenRouter's web search and returns a short answer with its sources.
  public func search(_ query: String) async throws -> String {
    guard profile.isOpenRouter else { return "Web search is not available for this agent." }
    guard let key = try apiKey(), !key.isEmpty else { throw Failure.noKey }
    var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"), timeoutInterval: 45)
    request.httpMethod = "POST"
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body: [String: Any] = [
      "model": profile.model, "temperature": 0, "max_tokens": Self.maxReplyTokens, "reasoning": ["effort": "low"],
      "plugins": [["id": "web", "max_results": 3]],
      "messages": [
        ["role": "system", "content": "Answer in at most four sentences, with concrete facts useful for fixing a failed local model install on macOS."],
        ["role": "user", "content": query],
      ],
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw Failure.malformed }
    guard http.statusCode == 200 else { throw Failure.http(http.statusCode) }
    struct Reply: Decodable {
      struct Choice: Decodable {
        struct Message: Decodable {
          struct Annotation: Decodable {
            struct Citation: Decodable { var url: String? }
            var url_citation: Citation?
          }
          var content: String?
          var annotations: [Annotation]?
        }
        var message: Message
      }
      var choices: [Choice]
    }
    guard let message = try? JSONDecoder().decode(Reply.self, from: data).choices.first?.message,
          let content = message.content else { throw Failure.malformed }
    let sources = (message.annotations ?? []).compactMap { $0.url_citation?.url }.filter { $0.hasPrefix("https://") }
    return content + (sources.isEmpty ? "" : "\nSources: " + Array(sources.prefix(3)).joined(separator: ", "))
  }
}
