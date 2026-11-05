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
  /// The body of one request. Thinking is off for OpenRouter: with it on, the model spent its whole token budget
  /// thinking and returned an empty or cut-off answer in 4 of 6 tries; with it off, 4 of 4 answers were valid JSON.
  func body(system: String, user: String, json: Bool, webSearch: Bool = false) -> [String: Any] {
    var body: [String: Any] = [
      "model": profile.model, "temperature": 0, "max_tokens": Self.maxReplyTokens,
      "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
    ]
    if json { body["response_format"] = ["type": "json_object"] }
    if profile.isOpenRouter { body["reasoning"] = ["enabled": false] }
    if webSearch { body["plugins"] = [["id": "web", "max_results": 3]] }
    return body
  }

  func requestBody(_ report: FailureReport, removable: [String]) throws -> Data {
    let reportJSON = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
    return try JSONSerialization.data(withJSONObject: body(
      system: RepairPlaybook.instructions,
      user: "Failure report:\n\(reportJSON)\nRemovable model ids: \(removable)", json: true))
  }

  /// One answer from the provider: its text and any web sources. A cut-off or empty answer is retried once.
  func complete(_ body: [String: Any], timeout: TimeInterval = 30) async throws -> (text: String, sources: [String]) {
    guard let key = try apiKey(), !key.isEmpty else { throw Failure.noKey }
    var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"), timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
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
        var finish_reason: String?
      }
      var choices: [Choice]
    }
    for attempt in 1...2 {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else { throw Failure.malformed }
      guard http.statusCode == 200 else { throw Failure.http(http.statusCode) }
      guard let choice = try? JSONDecoder().decode(Reply.self, from: data).choices.first else { throw Failure.malformed }
      let text = Self.unwrap(choice.message.content ?? "")
      if text.isEmpty || choice.finish_reason == "length" {
        if attempt == 1 { continue }
        throw Failure.malformed
      }
      let sources = (choice.message.annotations ?? []).compactMap { $0.url_citation?.url }.filter { $0.hasPrefix("https://") }
      return (text, sources)
    }
    throw Failure.malformed
  }

  /// Removes a Markdown code fence some providers put around JSON.
  static func unwrap(_ text: String) -> String {
    var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard t.hasPrefix("```") else { return t }
    t = String(t.drop(while: { $0 != "\n" }).dropFirst())
    if t.hasSuffix("```") { t = String(t.dropLast(3)) }
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func propose(for report: FailureReport, removable: [String]) async throws -> String {
    let reportJSON = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
    return try await complete(body(
      system: RepairPlaybook.instructions,
      user: "Failure report:\n\(reportJSON)\nRemovable model ids: \(removable)", json: true), timeout: 20).text
  }

  /// Looks a question up with OpenRouter's web search and returns a short answer with its sources.
  public func search(_ query: String) async throws -> String {
    guard profile.isOpenRouter else { return "Web search is not available for this agent." }
    let answer = try await complete(body(
      system: "Answer in at most four sentences, with concrete facts useful for fixing a failed local model install on macOS.",
      user: query, json: false, webSearch: true), timeout: 45)
    return answer.text + (answer.sources.isEmpty ? "" : "\nSources: " + Array(answer.sources.prefix(3)).joined(separator: ", "))
  }
}
