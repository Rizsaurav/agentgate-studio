import Foundation

public struct ChatMessage: Sendable, Equatable, Identifiable, Codable {
  public enum Role: String, Sendable, Codable { case system, user, assistant }
  public var id = UUID()
  public var role: Role
  public var content: String

  public init(role: Role, content: String) {
    self.role = role
    self.content = content
  }
}

public enum ChatError: Error, Equatable, CustomStringConvertible {
  case http(Int)
  case malformed

  public var description: String {
    switch self {
    case .http(let code): "The model server answered with HTTP \(code)."
    case .malformed: "The model server sent a reply that could not be read."
    }
  }
}

/// Streams a chat completion from any OpenAI-compatible endpoint.
public struct ChatClient: Sendable {
  public var baseURL: URL
  public var apiKey: String
  public var model: String

  public init(baseURL: URL, apiKey: String, model: String) {
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.model = model
  }

  public enum Chunk: Sendable, Equatable {
    case thinking(String)
    case text(String)
  }

  public func stream(_ messages: [ChatMessage], maxTokens: Int = 2048) -> AsyncThrowingStream<Chunk, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"), timeoutInterval: 300)
          request.httpMethod = "POST"
          request.setValue("application/json", forHTTPHeaderField: "Content-Type")
          request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
          request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "stream": true, "max_tokens": maxTokens,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
          ] as [String: Any])
          let (bytes, response) = try await URLSession.shared.bytes(for: request)
          let code = (response as? HTTPURLResponse)?.statusCode ?? 0
          guard code == 200 else { throw ChatError.http(code) }
          for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = line.dropFirst(6)
            if payload == "[DONE]" { break }
            guard let json = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
              throw ChatError.malformed
            }
            let delta = (json["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any]
            if let thinking = delta?["reasoning_content"] as? String, !thinking.isEmpty {
              continuation.yield(.thinking(thinking))
            }
            if let text = delta?["content"] as? String, !text.isEmpty { continuation.yield(.text(text)) }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
