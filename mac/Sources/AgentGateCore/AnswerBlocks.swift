import Foundation

/// An agent's answer split into blocks the chat can draw: headings, paragraphs with inline Markdown, code, and the
/// control lines the app reads (`PLAN READY`, `GOAL COMPLETE: …`), which are shown as small labels, not as prose.
public enum AnswerBlock: Equatable, Sendable {
  case heading(level: Int, text: String)
  case paragraph(String)
  case code(String)
  case marker(kind: Marker, detail: String)

  public enum Marker: String, Sendable { case planReady, goalComplete, goalBlocked, goalContinue }

  public static func parse(_ text: String) -> [AnswerBlock] {
    var blocks: [AnswerBlock] = []
    var paragraph: [String] = []
    var code: [String]?

    func flush() {
      let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      if !joined.isEmpty { blocks.append(.paragraph(joined)) }
      paragraph = []
    }

    for raw in text.components(separatedBy: "\n") {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("```") {
        if let lines = code {
          blocks.append(.code(lines.joined(separator: "\n")))
          code = nil
        } else {
          flush()
          code = []
        }
        continue
      }
      if code != nil {
        code?.append(raw)
        continue
      }
      if let marker = marker(line) {
        flush()
        blocks.append(marker)
        continue
      }
      let hashes = line.prefix { $0 == "#" }.count
      if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
        flush()
        let title = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        blocks.append(.heading(level: hashes, text: title.hasSuffix(":") ? String(title.dropLast()) : title))
        continue
      }
      if line.isEmpty { flush() } else { paragraph.append(raw) }
    }
    if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
    flush()
    return blocks
  }

  static func marker(_ line: String) -> AnswerBlock? {
    let plain = line.trimmingCharacters(in: CharacterSet(charactersIn: "*_` "))
    let upper = plain.uppercased()
    if upper == "PLAN READY" { return .marker(kind: .planReady, detail: "") }
    for (prefix, kind) in [("GOAL COMPLETE", Marker.goalComplete), ("GOAL BLOCKED", .goalBlocked), ("GOAL CONTINUE", .goalContinue)]
    where upper.hasPrefix(prefix) {
      let detail = plain.dropFirst(prefix.count).drop { $0 == ":" || $0 == " " }
      return .marker(kind: kind, detail: String(detail))
    }
    return nil
  }
}
