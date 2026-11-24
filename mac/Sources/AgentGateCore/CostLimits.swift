import Foundation

/// Spending limits for cloud models, in US dollars. Nil means no limit at that level.
public struct CloudLimits: Codable, Sendable, Equatable {
  public var perTurn: Double?
  public var perSession: Double?
  public var perDay: Double?

  public init(perTurn: Double? = nil, perSession: Double? = nil, perDay: Double? = nil) {
    self.perTurn = perTurn
    self.perSession = perSession
    self.perDay = perDay
  }

  /// Keeps only usable values: a limit is a positive amount, anything else is no limit.
  public var cleaned: CloudLimits {
    func ok(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
    return CloudLimits(perTurn: ok(perTurn), perSession: ok(perSession), perDay: ok(perDay))
  }
}

/// Why a cloud request was not sent.
public enum CostLimitReached: Error, Sendable, Equatable, CustomStringConvertible {
  case turn(limit: Double), session(limit: Double), day(limit: Double)

  public var description: String {
    switch self {
    case .turn(let limit):
      "Stopped: the next request would go over this turn's limit of \(Spend.format(limit)). Raise it on Profile to continue."
    case .session(let limit):
      "Stopped: this session has reached its limit of \(Spend.format(limit)). Raise it on Profile or restart the app."
    case .day(let limit):
      "Stopped: today's cloud spend has reached its limit of \(Spend.format(limit)). Nothing more is sent until tomorrow, or raise it on Profile."
    }
  }
}

public enum Spend {
  public static func format(_ dollars: Double) -> String {
    dollars < 0.01 && dollars > 0 ? String(format: "$%.4f", dollars) : String(format: "$%.2f", dollars)
  }
}

/// Day totals of cloud spend, saved locally (0600). Holds dates and amounts only.
public struct SpendLedger: Sendable {
  public let file: URL
  /// Days kept, newest first.
  public var keepDays = 90

  public init(file: URL = AppPaths.support.appendingPathComponent("spend.json")) { self.file = file }

  public static func day(_ date: Date, calendar: Calendar = .current) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
  }

  public func spent(on date: Date = Date()) -> Double { load()[Self.day(date)] ?? 0 }

  public func add(_ dollars: Double, on date: Date = Date()) throws {
    guard dollars.isFinite, dollars > 0 else { return }
    var days = load()
    days[Self.day(date), default: 0] += dollars
    let kept = days.keys.sorted(by: >).prefix(keepDays)
    days = days.filter { kept.contains($0.key) }
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(days).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }

  private func load() -> [String: Double] {
    guard let data = try? Data(contentsOf: file) else { return [:] }
    return (try? JSONDecoder().decode([String: Double].self, from: data)) ?? [:]
  }
}

/// Checks every cloud request against the limits before it is sent, and records what each reply cost.
/// One guard lives for one app session; `beginTurn` starts a turn's count.
public final class CostGuard: @unchecked Sendable {
  private let lock = NSLock()
  private let ledger: SpendLedger
  private let now: @Sendable () -> Date
  private var limits: CloudLimits
  private var turn = 0.0
  private var session = 0.0
  /// The most one reply has cost so far: the guess for what the next one may cost.
  private var largestReply = 0.0
  private var unpriced = 0

  public init(limits: CloudLimits, ledger: SpendLedger = SpendLedger(), now: @escaping @Sendable () -> Date = Date.init) {
    self.limits = limits.cleaned
    self.ledger = ledger
    self.now = now
  }

  public func setLimits(_ limits: CloudLimits) { lock.withLock { self.limits = limits.cleaned } }
  public func beginTurn() { lock.withLock { turn = 0 } }

  public var spentThisTurn: Double { lock.withLock { turn } }
  public var spentThisSession: Double { lock.withLock { session } }
  public var spentToday: Double { ledger.spent(on: now()) }
  /// Replies whose provider did not say what they cost.
  public var unpricedReplies: Int { lock.withLock { unpriced } }

  /// Throws when the next request would go over a limit. Called before anything is sent.
  public func allowRequest() throws {
    let today = ledger.spent(on: now())
    try lock.withLock {
      let next = largestReply
      if let day = limits.perDay, today >= day || today + next > day { throw CostLimitReached.day(limit: day) }
      if let max = limits.perSession, session >= max || session + next > max {
        throw CostLimitReached.session(limit: max)
      }
      if let max = limits.perTurn, turn >= max || turn + next > max { throw CostLimitReached.turn(limit: max) }
    }
  }

  /// Records one reply's provider-reported cost. Nil means the provider did not say.
  public func record(cost: Double?) {
    guard let cost, cost.isFinite, cost >= 0 else {
      lock.withLock { unpriced += 1 }
      return
    }
    lock.withLock {
      turn += cost
      session += cost
      largestReply = max(largestReply, cost)
    }
    try? ledger.add(cost, on: now())
  }
}

/// The limits the user set on Profile, saved locally.
public struct CloudLimitsStore: Sendable {
  public let file: URL

  public init(file: URL = AppPaths.support.appendingPathComponent("cloud-limits.json")) { self.file = file }

  public func load() -> CloudLimits {
    guard let data = try? Data(contentsOf: file) else { return CloudLimits() }
    return ((try? JSONDecoder().decode(CloudLimits.self, from: data)) ?? CloudLimits()).cleaned
  }

  public func save(_ limits: CloudLimits) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(limits.cleaned).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
}
