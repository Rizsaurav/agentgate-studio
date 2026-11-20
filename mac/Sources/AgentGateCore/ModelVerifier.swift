import Foundation

public enum Readiness: String, Codable, Sendable {
  /// Answers and calls tools: usable for agent sessions.
  case ready
  /// Answers, but cannot call tools reliably.
  case chatOnly
}

public enum VerifyError: Error, Equatable, CustomStringConvertible {
  case noReply(String)
  case timedOut

  public var description: String {
    switch self {
    case .noReply(let detail): "The model did not give a usable reply (\(detail))."
    case .timedOut: "The model did not answer in time."
    }
  }
}

/// Proves a loaded model works before it is offered: a short reply, then a tool call.
public struct ModelVerifier: Sendable {
  public var timeout: TimeInterval = 120

  public init() {}

  public func verify(baseURL: URL, apiKey: String, model: String) async throws -> Readiness {
    let reply = try await chat(baseURL, apiKey, [
      "model": model, "max_tokens": 32, "temperature": 0,
      "messages": [["role": "user", "content": "Reply with one word: ready"]],
    ])
    let content = (reply["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !content.isEmpty else { throw VerifyError.noReply("empty answer") }
    return try await callsTools(baseURL, apiKey, model) ? .ready : .chatOnly
  }

  /// Asks for a weather lookup and checks the model calls the tool with the right argument.
  func callsTools(_ baseURL: URL, _ apiKey: String, _ model: String) async throws -> Bool {
    let tool: [String: Any] = [
      "type": "function",
      "function": [
        "name": "get_weather", "description": "Current weather for a city.",
        "parameters": [
          "type": "object", "properties": ["city": ["type": "string"]], "required": ["city"],
        ],
      ],
    ]
    let message = try await chat(baseURL, apiKey, [
      "model": model, "max_tokens": 128, "temperature": 0, "tools": [tool], "tool_choice": "auto",
      "messages": [["role": "user", "content": "What is the weather in Paris right now? Use the tool."]],
    ])
    guard let call = (message["tool_calls"] as? [[String: Any]])?.first,
          let function = call["function"] as? [String: Any],
          function["name"] as? String == "get_weather",
          let arguments = (function["arguments"] as? String).flatMap({ $0.data(using: .utf8) }),
          let parsed = try? JSONSerialization.jsonObject(with: arguments) as? [String: Any],
          let city = parsed["city"] as? String else { return false }
    return city.localizedCaseInsensitiveContains("paris")
  }

  /// Sends one chat completion and returns the first choice's message.
  func chat(_ baseURL: URL, _ apiKey: String, _ body: [String: Any]) async throws -> [String: Any] {
    var payload = body
    // Thinking models (Qwen3) answer directly for these short checks.
    payload["chat_template_kwargs"] = ["enable_thinking": false]
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"), timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
    let data: Data, response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch let error as URLError where error.code == .timedOut {
      throw VerifyError.timedOut
    }
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw VerifyError.noReply("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else {
      throw VerifyError.noReply("unexpected response shape")
    }
    return message
  }
}
