import Foundation

/// Something fixed code noticed while an install runs that the repair rules do not handle (#107).
/// It is only ever reported: acting on it is a repair (#72), never the watcher's job.
public struct WatchSignal: Sendable, Equatable {
  public enum Kind: String, Sendable {
    case slowDownload, stalled, memoryPressure, thermal
  }

  public var kind: Kind
  /// One plain sentence with the numbers, written by fixed code. The agent may reword it, never add to it.
  public var fact: String
}

/// What the Mac looked like at one moment, for the signals that are not about the download.
public struct SystemSample: Sendable, Equatable {
  public var swapUsedBytes: UInt64
  public var thermal: ProcessInfo.ThermalState
  /// macOS reported memory pressure (warning or critical) since the last sample.
  public var memoryPressure: Bool

  public init(swapUsedBytes: UInt64, thermal: ProcessInfo.ThermalState, memoryPressure: Bool) {
    self.swapUsedBytes = swapUsedBytes
    self.thermal = thermal
    self.memoryPressure = memoryPressure
  }

  /// This Mac, now. Swap is read with sysctl; pressure events come from the caller's dispatch source.
  public static func current(memoryPressure: Bool) -> SystemSample {
    var usage = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    let swap = sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 ? usage.xsu_used : 0
    return SystemSample(swapUsedBytes: swap, thermal: ProcessInfo.processInfo.thermalState, memoryPressure: memoryPressure)
  }
}

/// Watches one install. Feed it every progress update and a system sample every few seconds; it returns
/// a signal when there is something to say. At most one note a minute and five per install, and each kind
/// at most once, so a healthy install says nothing and a troubled one is not noisy.
public struct InstallWatcher: Sendable {
  public static let noteInterval: TimeInterval = 60
  public static let maxNotes = 5

  /// The download is slow when its rate over the last `recentWindow` seconds is under this share of the
  /// best rate seen, for at least `slowFor` seconds, or when what is left would take over `longETA`.
  static let slowShare = 0.25
  static let recentWindow: TimeInterval = 6
  static let slowFor: TimeInterval = 6
  static let warmUp: TimeInterval = 8
  static let longETA: TimeInterval = 3600
  static let stallAfter: TimeInterval = 20
  /// Swap that grows by more than this during the load means the model is pushing the Mac into swap.
  static let swapGrowth: UInt64 = 512 << 20

  private var samples: [(time: Date, bytes: UInt64)] = []
  private var downloadStart: Date?
  private var peak: Double = 0
  private var slowSince: Date?
  private var lastProgress: (time: Date, bytes: UInt64)?
  private var total: UInt64 = 0
  private var step: InstallStep?
  private var swapAtLoad: UInt64?
  private var said: Set<WatchSignal.Kind> = []
  private var notes: [Date] = []

  public init() {}

  public mutating func observe(_ update: InstallUpdate, at now: Date) -> WatchSignal? {
    if step != update.step, update.step == .load { swapAtLoad = nil }
    step = update.step
    guard update.step == .download, update.totalBytes > 0 else { return nil }
    total = update.totalBytes
    if downloadStart == nil { downloadStart = now }
    if lastProgress == nil || update.completedBytes > lastProgress!.bytes { lastProgress = (now, update.completedBytes) }
    samples.append((now, update.completedBytes))
    samples.removeAll { now.timeIntervalSince($0.time) > 120 }
    return check(at: now)
  }

  public mutating func observe(_ system: SystemSample, at now: Date) -> WatchSignal? {
    if system.thermal == .serious || system.thermal == .critical {
      if let note = note(.thermal, "The Mac is hot and has slowed itself down, so this step will take longer.", at: now) { return note }
    }
    if step == .load || step == .test {
      let base = swapAtLoad ?? system.swapUsedBytes
      swapAtLoad = base
      let grown = system.swapUsedBytes > base ? system.swapUsedBytes - base : 0
      if system.memoryPressure || grown > Self.swapGrowth {
        let detail = grown > Self.swapGrowth ? " macOS moved \(ModelPlanner.gb(grown)) to disk to make room." : ""
        if let note = note(.memoryPressure, "Memory is tight while the model loads; it may be slow or fail.\(detail) Closing other apps helps.", at: now) {
          return note
        }
      }
    }
    return step == .download ? check(at: now) : nil
  }

  private mutating func check(at now: Date) -> WatchSignal? {
    // A finished download has nothing left to be slow about.
    guard let start = downloadStart, let last = lastProgress, last.bytes < total else { return nil }
    if now.timeIntervalSince(last.time) >= Self.stallAfter {
      return note(.stalled, "No data has arrived for \(Int(now.timeIntervalSince(last.time))) seconds. The download will retry on its own if this goes on.", at: now)
    }
    // Peak over short windows, current over the recent window.
    if let rate = rate(over: 2, at: now) { peak = max(peak, rate) }
    guard now.timeIntervalSince(start) >= Self.warmUp, let current = rate(over: Self.recentWindow, at: now) else { return nil }
    let remaining = Double(total - min(total, last.bytes))
    let eta = current > 0 ? remaining / current : .infinity
    if current < peak * Self.slowShare || eta > Self.longETA {
      slowSince = slowSince ?? now
      if now.timeIntervalSince(slowSince!) >= Self.slowFor {
        let speed = "\(Self.mbps(current)) MB/s"
        let fact = current < peak * Self.slowShare
          ? "The download slowed to \(speed), from \(Self.mbps(peak)) MB/s earlier. The server or the network is slower now; it keeps going."
          : "At \(speed) the rest of the download takes about \(Self.duration(eta)). It keeps going."
        return note(.slowDownload, fact, at: now)
      }
    } else {
      slowSince = nil
    }
    return nil
  }

  /// Bytes per second over the last `seconds`, or nil until that much time has been seen.
  private func rate(over seconds: TimeInterval, at now: Date) -> Double? {
    guard let newest = samples.last, let oldest = samples.last(where: { now.timeIntervalSince($0.time) >= seconds }) else { return nil }
    let span = newest.time.timeIntervalSince(oldest.time)
    return span > 0 ? Double(newest.bytes - min(newest.bytes, oldest.bytes)) / span : nil
  }

  private mutating func note(_ kind: WatchSignal.Kind, _ fact: String, at now: Date) -> WatchSignal? {
    guard !said.contains(kind), notes.count < Self.maxNotes,
          notes.last.map({ now.timeIntervalSince($0) >= Self.noteInterval }) ?? true else { return nil }
    said.insert(kind)
    notes.append(now)
    return WatchSignal(kind: kind, fact: fact)
  }

  static func mbps(_ bytesPerSecond: Double) -> String { String(format: "%.1f", bytesPerSecond / 1_000_000) }

  static func duration(_ seconds: TimeInterval) -> String {
    seconds >= 3600 ? String(format: "%.1f hours", seconds / 3600) : "\(Int((seconds / 60).rounded())) minutes"
  }
}

extension AgentAssistant {
  static let watchInstructions = """
    Rewrite this status note about a model install as one short, calm sentence for a non-technical user. \
    Keep every number. Do not suggest anything you will do: you cannot act. Reply with the sentence only.
    """

  /// The agent's wording of a watcher note; the caller keeps the fixed sentence if this fails.
  public func phrase(_ signal: WatchSignal) async throws -> String {
    let text = try await complete(body(system: Self.watchInstructions, user: signal.fact, json: false), timeout: 15).text
      .trimmingCharacters(in: .whitespacesAndNewlines)
    // One sentence of plain text, or the fixed one.
    guard !text.isEmpty, text.count <= 240, !text.contains("\n") else { return signal.fact }
    return text
  }
}
