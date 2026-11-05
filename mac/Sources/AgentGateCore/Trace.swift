import Foundation

/// One step of a turn: a model call or a tool call, with when it started, how long it took, what it
/// cost and how it ended. Text is redacted (keys, private paths) before it is kept.
public struct TraceSpan: Codable, Sendable, Equatable, Identifiable {
  public enum Kind: String, Codable, Sendable { case model, tool }
  public enum Outcome: String, Codable, Sendable { case running, completed, failed, refused }

  public var id: String
  public var kind: Kind
  /// The tool name, or the model name.
  public var name: String
  /// The command or path for a tool, already redacted.
  public var detail: String
  public var start: Date
  public var end: Date?
  public var outcome: Outcome
  /// The tool's output or the refusal reason, redacted and cut to a few lines.
  public var output: String
  public var tokensIn: Int?
  public var tokensOut: Int?
  /// In US dollars, as the provider reported it.
  public var cost: Double?

  public var duration: TimeInterval? { end.map { $0.timeIntervalSince(start) } }
}

/// Everything that happened in one turn, in the order it started.
public struct Trace: Codable, Sendable, Equatable, Identifiable {
  public var id: UUID
  public var project: String
  public var started: Date
  public var finished: Date?
  public var spans: [TraceSpan]

  public var tokensIn: Int { spans.compactMap(\.tokensIn).reduce(0, +) }
  public var tokensOut: Int { spans.compactMap(\.tokensOut).reduce(0, +) }
  public var cost: Double { spans.compactMap(\.cost).reduce(0, +) }
  public var duration: TimeInterval? { finished.map { $0.timeIntervalSince(started) } }
}

/// Builds the trace of the turn in progress from the harness's events. One recorder per session.
public final class TraceRecorder: @unchecked Sendable {
  static let detailLimit = 500
  static let outputLimit = 2000

  private let folder: URL
  private let project: String
  private let now: @Sendable () -> Date
  private let lock = NSLock()
  private var trace: Trace?

  public init(folder: URL, project: String, now: @escaping @Sendable () -> Date = { Date() }) {
    self.folder = folder
    self.project = project
    self.now = now
  }

  /// Starts a new turn. A turn still open is dropped, so call `finishTurn` first to keep it.
  public func beginTurn() {
    lock.withLock {
      trace = Trace(id: UUID(), project: project, started: now(), finished: nil, spans: [])
    }
  }

  /// A tool call moved on (pending, running, completed or error). Updates are idempotent and may
  /// arrive out of order; the span keeps its first start time and its place in the turn.
  public func tool(id: String, name: String, status: String, detail: String, output: String) {
    lock.withLock {
      ensureTurn()
      let outcome: TraceSpan.Outcome = switch status {
      case "completed": .completed
      case "error": .failed
      default: .running
      }
      let at = now()
      if let index = trace!.spans.firstIndex(where: { $0.id == id }) {
        var span = trace!.spans[index]
        // A finished call stays as it finished; a late or repeated update cannot change it.
        guard span.outcome == .running else { return }
        if !detail.isEmpty { span.detail = clean(detail, limit: Self.detailLimit) }
        if !output.isEmpty { span.output = clean(output, limit: Self.outputLimit) }
        if outcome != .running {
          span.outcome = outcome
          span.end = at
        }
        trace!.spans[index] = span
      } else {
        trace!.spans.append(TraceSpan(
          id: id, kind: .tool, name: name, detail: clean(detail, limit: Self.detailLimit), start: at,
          end: outcome == .running ? nil : at, outcome: outcome, output: clean(output, limit: Self.outputLimit)))
      }
    }
  }

  /// A tool call the app refused before it ran (permission gate, tool-call check, the user).
  public func refused(id: String, name: String, detail: String, reason: String) {
    lock.withLock {
      ensureTurn()
      let at = now()
      let span = TraceSpan(
        id: id, kind: .tool, name: name, detail: clean(detail, limit: Self.detailLimit), start: at, end: at,
        outcome: .refused, output: clean(reason, limit: Self.outputLimit))
      if let index = trace!.spans.firstIndex(where: { $0.id == id }) {
        trace!.spans[index] = span
      } else {
        trace!.spans.append(span)
      }
    }
  }

  /// A model call with what the provider reported for it.
  public func model(
    id: String, name: String, start: Date, end: Date?, tokensIn: Int?, tokensOut: Int?, cost: Double?, failed: Bool = false
  ) {
    lock.withLock {
      ensureTurn()
      let span = TraceSpan(
        id: id, kind: .model, name: name, detail: "", start: start, end: end,
        outcome: failed ? .failed : (end == nil ? .running : .completed), output: "",
        tokensIn: tokensIn, tokensOut: tokensOut, cost: cost)
      if let index = trace!.spans.firstIndex(where: { $0.id == id }) {
        trace!.spans[index] = span
      } else {
        trace!.spans.append(span)
      }
    }
  }

  /// The turn so far, for the timeline while it runs.
  public var current: Trace? { lock.withLock { trace } }

  /// Ends the turn: anything still running is marked as stopped with the turn. Nil if no turn was open.
  @discardableResult
  public func finishTurn() -> Trace? {
    lock.withLock {
      guard var finished = trace else { return nil }
      let at = now()
      finished.finished = at
      for index in finished.spans.indices where finished.spans[index].outcome == .running {
        finished.spans[index].end = at
        finished.spans[index].outcome = .failed
        if finished.spans[index].output.isEmpty { finished.spans[index].output = "Stopped when the turn ended." }
      }
      trace = nil
      return finished
    }
  }

  private func ensureTurn() {
    if trace == nil { trace = Trace(id: UUID(), project: project, started: now(), finished: nil, spans: []) }
  }

  private func clean(_ text: String, limit: Int) -> String {
    let redacted = Redaction.clean(text, root: folder, label: "<project>")
    return redacted.count > limit ? String(redacted.prefix(limit - 1)) + "…" : redacted
  }
}

/// Finished traces of one project, saved locally in a private folder; the newest `keep` are kept.
public struct TraceStore: Sendable {
  public let directory: URL
  public let keep: Int

  public init(directory: URL, keep: Int = 200) {
    self.directory = directory
    self.keep = keep
  }

  public init(project: UUID, keep: Int = 200) {
    self.init(directory: AppPaths.support.appendingPathComponent("traces/\(project.uuidString)", isDirectory: true), keep: keep)
  }

  public func save(_ trace: Trace) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let file = directory.appendingPathComponent(Self.name(trace))
    try Self.encoder.encode(trace).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    for old in try files().dropFirst(keep) { try? FileManager.default.removeItem(at: old) }
  }

  /// Newest first. A file that cannot be read is skipped, never fatal.
  public func list() throws -> [Trace] {
    try files().compactMap { try? Self.decoder.decode(Trace.self, from: Data(contentsOf: $0)) }
  }

  /// A readable JSON file of one trace for a bug report. Redacted again on the way out, so nothing
  /// that slipped into a saved trace (an older format, a hand edit) leaves this Mac.
  public static func export(_ trace: Trace, folder: URL) throws -> Data {
    var copy = trace
    for index in copy.spans.indices {
      copy.spans[index].detail = Redaction.clean(copy.spans[index].detail, root: folder, label: "<project>")
      copy.spans[index].output = Redaction.clean(copy.spans[index].output, root: folder, label: "<project>")
    }
    copy.project = Redaction.clean(copy.project, root: folder, label: "<project>")
    let encoder = Self.encoder
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(copy)
  }

  private func files() throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
  }

  /// Sortable by time: newest last alphabetically.
  static func name(_ trace: Trace) -> String {
    let millis = Int64(trace.started.timeIntervalSince1970 * 1000)
    return String(format: "%013lld-%@.json", millis, trace.id.uuidString)
  }

  /// ISO 8601 with milliseconds, so durations survive saving. Reading is thread-safe.
  nonisolated(unsafe) static let time: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(time.string(from: date))
    }
    return encoder
  }

  static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let text = try decoder.singleValueContainer().decode(String.self)
      guard let date = time.date(from: text) else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a date: \(text)"))
      }
      return date
    }
    return decoder
  }
}
