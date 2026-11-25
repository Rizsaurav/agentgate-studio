import Foundation

/// Finds past chats by what was said in them: the user's messages, the answers, and the commands and files the
/// agent touched. Every word of the query must appear somewhere in the chat; chats that match more often, and
/// more recently, come first. Runs on this Mac over the saved chats; nothing is indexed elsewhere.
public enum SessionSearch {
  public struct Hit: Sendable, Equatable, Identifiable {
    public var id: UUID { sessionId }
    public var sessionId: UUID
    /// The text around the first match, on one line.
    public var snippet: String
    public var matches: Int
  }

  public static let snippetRadius = 60

  public static func search(_ query: String, in sessions: [Session], limit: Int = 20) -> [Hit] {
    let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.count >= 2 }
    guard !words.isEmpty else { return [] }
    var hits: [(hit: Hit, date: Date)] = []
    for session in sessions {
      let texts = searchableTexts(session)
      let joined = texts.joined(separator: "\n").lowercased()
      guard words.allSatisfy(joined.contains) else { continue }
      let matches = words.reduce(0) { $0 + occurrences(of: $1, in: joined) }
      let first = texts.first { text in words.contains { text.lowercased().contains($0) } } ?? ""
      hits.append((Hit(sessionId: session.id, snippet: snippet(of: first, around: words), matches: matches), session.createdAt))
    }
    return hits.sorted { ($0.hit.matches, $0.date) > ($1.hit.matches, $1.date) }.prefix(limit).map(\.hit)
  }

  /// The words a chat holds: messages, a goal's objective, and the commands and paths of its steps.
  static func searchableTexts(_ session: Session) -> [String] {
    var texts = session.goal.map { [$0.objective] } ?? []
    for message in session.messages {
      texts.append(message.content)
      for step in message.steps ?? [] where step.kind == .tool || step.kind == .refused {
        texts.append(step.text)
      }
    }
    return texts.filter { !$0.isEmpty }
  }

  static func occurrences(of word: String, in text: String) -> Int {
    var count = 0
    var range = text.startIndex..<text.endIndex
    while let found = text.range(of: word, range: range) {
      count += 1
      range = found.upperBound..<text.endIndex
    }
    return count
  }

  static func snippet(of text: String, around words: [String]) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " ")
    guard let match = words.compactMap({ flat.lowercased().range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else {
      return String(flat.prefix(snippetRadius * 2))
    }
    let lower = flat.lowercased()
    let startOffset = max(lower.distance(from: lower.startIndex, to: match.lowerBound) - snippetRadius, 0)
    let start = flat.index(flat.startIndex, offsetBy: startOffset)
    let end = flat.index(start, offsetBy: snippetRadius * 2, limitedBy: flat.endIndex) ?? flat.endIndex
    return (startOffset > 0 ? "…" : "") + flat[start..<end].trimmingCharacters(in: .whitespaces) + (end < flat.endIndex ? "…" : "")
  }
}
