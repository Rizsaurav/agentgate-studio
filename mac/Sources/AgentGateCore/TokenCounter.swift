import Foundation

/// Where a model runs. Local and cloud use are counted in separate rows.
public enum ModelLocation: String, Codable, Sendable, CaseIterable {
  case local, cloud
}

/// Tokens one model has processed, as reported by its engine or provider. Holds counts only, never text.
public struct TokenCount: Codable, Sendable, Equatable, Identifiable {
  public var model: String
  public var name: String
  public var location: ModelLocation
  public var prompt: Int
  public var generated: Int
  /// Replies that came back without usage. Counted as replies, never guessed as tokens.
  public var unreported: Int
  public var lastUsed: Date

  public var id: String { TokenCounter.key(model, location) }
  public var total: Int { prompt + generated }
}

/// One reply's usage, as the engine or provider reported it.
public struct TokenUsage: Sendable, Equatable {
  public var prompt: Int
  public var generated: Int

  public init(prompt: Int, generated: Int) {
    self.prompt = prompt
    self.generated = generated
  }

  /// Nil for values a reply cannot have (negative, absurdly large), so a broken reply never corrupts the counter.
  public static func reported(prompt: Int, generated: Int) -> TokenUsage? {
    let limit = 100_000_000
    guard (0...limit).contains(prompt), (0...limit).contains(generated) else { return nil }
    return TokenUsage(prompt: prompt, generated: generated)
  }
}

/// Per-model token counters, saved locally (0600) so they survive restarts.
public struct TokenCounter: Sendable {
  public let file: URL

  public init(file: URL = AppPaths.support.appendingPathComponent("tokens.json")) { self.file = file }

  static func key(_ model: String, _ location: ModelLocation) -> String { "\(location.rawValue):\(model)" }

  /// Every counter, local first, then by most recent use.
  public func all() -> [TokenCount] {
    load().values.sorted {
      $0.location != $1.location ? $0.location == .local : $0.lastUsed > $1.lastUsed
    }
  }

  public func count(model: String, location: ModelLocation) -> TokenCount? { load()[Self.key(model, location)] }

  /// Totals across every model, per location.
  public func total(_ location: ModelLocation) -> Int {
    load().values.filter { $0.location == location }.reduce(0) { $0 + $1.total }
  }

  /// Adds one reply. Nil usage means the reply had none: it is noted, and no tokens are added.
  public func record(
    _ usage: TokenUsage?, model: String, name: String, location: ModelLocation, now: Date = Date()
  ) throws {
    var counts = load()
    let key = Self.key(model, location)
    var count = counts[key] ?? TokenCount(
      model: model, name: name, location: location, prompt: 0, generated: 0, unreported: 0, lastUsed: now)
    count.name = name
    count.lastUsed = now
    if let usage {
      count.prompt += usage.prompt
      count.generated += usage.generated
    } else {
      count.unreported += 1
    }
    counts[key] = count
    try save(counts)
  }

  /// Clears one model's counter; the others are untouched.
  public func reset(model: String, location: ModelLocation) throws {
    var counts = load()
    guard counts.removeValue(forKey: Self.key(model, location)) != nil else { return }
    try save(counts)
  }

  private func load() -> [String: TokenCount] {
    guard let data = try? Data(contentsOf: file) else { return [:] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let list = try? decoder.decode([TokenCount].self, from: data) else { return [:] }
    return Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
  }

  private func save(_ counts: [String: TokenCount]) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(counts.values.sorted { $0.id < $1.id })
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
}
