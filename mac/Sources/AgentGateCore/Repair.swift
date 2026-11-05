import Foundation

/// The only things a repair can do. Nothing outside this list runs, whoever proposes it.
public enum RepairOperation: Sendable, Equatable, Hashable {
  /// Download again; a partial file is resumed, a bad one is replaced.
  case retryDownload
  /// Plan again one quantization level below the one that failed.
  case lowerQuantization
  /// Plan again with the next smaller context.
  case reduceContext
  /// Start the engine again (a new port is chosen).
  case restartRuntime
  /// Delete another installed model to make room.
  case freeDisk(modelId: String)
  /// Stop, and remove the incomplete files of this install.
  case cancelAndCleanUp
  /// Plan again with at most this context size (one of the sizes the planner offers).
  case setContext(Int)
  /// Plan again with at most this quantization.
  case setQuantization(Quantization)
  /// Download from this mirror instead. Checksums are still checked against the catalog, so a mirror
  /// cannot change what is installed. Only mirrors on `mirrors` are accepted.
  case useMirror(String)
  /// A shell command the assistant wants run to look at something. It is never a repair on its own:
  /// the same rules as the agent's terminal apply, the user approves it, and its output goes back to the assistant.
  case runCommand(String)

  /// Every operation an assistant may propose, with how to ask for it. The playbook given to every agent is
  /// generated from this, so what agents are told cannot drift from what the app accepts.
  public static let catalogue: [(name: String, help: String, example: String)] = [
    ("retryDownload", "download again, resuming a partial file", #"{"op":"retryDownload"}"#),
    ("restartRuntime", "start the model engine again on a new port", #"{"op":"restartRuntime"}"#),
    ("cancelAndCleanUp", "stop and remove the incomplete files of this install", #"{"op":"cancelAndCleanUp"}"#),
    ("reduceContext", "plan again with the next smaller context", #"{"op":"reduceContext"}"#),
    ("lowerQuantization", "plan again one quality level lower", #"{"op":"lowerQuantization"}"#),
    ("setContext", "plan with this context size; add \"to\": \"8192\" | \"16384\" | \"32768\"", #"{"op":"setContext","to":"8192"}"#),
    ("setQuantization", "plan with at most this quality; add \"to\": \"Q8_0\" | \"Q6_K\" | \"Q5_K_M\" | \"MXFP4\" | \"Q4_K_M\" | \"Q3_K_M\"", #"{"op":"setQuantization","to":"Q4_K_M"}"#),
    ("useMirror", "download from a mirror when the main server keeps failing; add \"to\": \"https://hf-mirror.com\"; checksums still apply", #"{"op":"useMirror","to":"https://hf-mirror.com"}"#),
    ("freeDisk", "delete another installed model to make room; add \"modelId\", one of the removable ids you are given", #"{"op":"freeDisk","modelId":"old"}"#),
  ]

  /// The only download mirrors an assistant may choose.
  public static let mirrors = ["https://hf-mirror.com"]

  public var name: String {
    switch self {
    case .retryDownload: "retryDownload"
    case .lowerQuantization: "lowerQuantization"
    case .reduceContext: "reduceContext"
    case .restartRuntime: "restartRuntime"
    case .freeDisk: "freeDisk"
    case .cancelAndCleanUp: "cancelAndCleanUp"
    case .setContext: "setContext"
    case .setQuantization: "setQuantization"
    case .runCommand: "runCommand"
    case .useMirror: "useMirror"
    }
  }

  /// How much oversight a repair gets, by risk.
  public enum Tier: Int, Sendable, Comparable {
    /// Reversible and cheap: runs and is logged.
    case act
    /// Recoverable but worth knowing about: runs with a note in the bar (asked first when the user chose Careful).
    case notify
    /// Deletes files, lowers quality, or runs a command: always the user's yes.
    case ask

    public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
  }

  public func tier(downloadBytes: UInt64) -> Tier {
    switch self {
    case .freeDisk, .lowerQuantization, .setQuantization, .runCommand: .ask
    case .useMirror: .notify
    case .retryDownload: downloadBytes > MemoryBudget.gib ? .notify : .act
    case .reduceContext, .restartRuntime, .cancelAndCleanUp, .setContext: .act
    }
  }

  /// Whether the user must say yes first, given how much autonomy they chose.
  public func needsApproval(downloadBytes: UInt64, autonomy: Autonomy = .careful) -> Bool {
    let tier = tier(downloadBytes: downloadBytes)
    return tier == .ask || (tier == .notify && autonomy == .careful)
  }

  public var summary: String {
    switch self {
    case .retryDownload: "Download again, resuming where it stopped."
    case .lowerQuantization: "Use a smaller, lower-quality version of the model."
    case .reduceContext: "Use a shorter context so the model needs less memory."
    case .restartRuntime: "Start the model engine again."
    case .freeDisk(let id): "Delete the installed model \(id) to free disk space."
    case .cancelAndCleanUp: "Stop and remove the incomplete files."
    case .setContext(let size): "Use a \(size / 1024)K context."
    case .setQuantization(let quant): "Use the \(quant.rawValue) version of the model."
    case .runCommand(let command): "Run: \(command)"
    case .useMirror(let host): "Download from \(host) instead. The file is still checked against its published checksum."
    }
  }
}

/// How much the supervising agent may do without asking.
public enum Autonomy: String, Codable, Sendable, CaseIterable {
  /// Asks before anything beyond retries and restarts.
  case careful
  /// Also switches to a listed mirror or retries a big download on its own, and says so in the bar.
  case balanced

  public var summary: String {
    switch self {
    case .careful: "Asks before switching download source or re-downloading over 1 GB."
    case .balanced: "Switches to a listed mirror or retries a big download on its own and tells you. Still asks before deleting, lowering quality or running commands."
    }
  }
}

/// What went wrong, in terms a repair can act on.
public enum FailureClass: String, Sendable, Equatable, Codable {
  case network, diskFull, corruptFile, outOfMemory, engineCrashed, portInUse, loadTimedOut
  /// No repair applies: the app itself is damaged, or the model cannot run on this Mac.
  case unrepairable

  public static func classify(_ failure: InstallFailure) -> FailureClass {
    switch failure.cause {
    case let error as DownloadError:
      switch error {
      case .diskFull, .notEnoughDisk: return .diskFull
      case .checksumMismatch, .sizeMismatch: return .corruptFile
      case .http, .stalled, .network, .gaveUp, .writeFailed: return .network
      case .alreadyInProgress, .cancelled: return .unrepairable
      }
    case let error as RuntimeError:
      switch error {
      case .outOfMemory: return .outOfMemory
      case .loadTimedOut: return .loadTimedOut
      case .noFreePort: return .portInUse
      case .exited(_, let tail): return tail.contains("couldn't bind") ? .portInUse : .engineCrashed
      case .missingBinary: return .unrepairable
      }
    case PlanError.incompatible(let reason):
      return reason.contains("free disk") ? .diskFull : .unrepairable
    default:
      return .unrepairable
    }
  }

  /// The fixed repair for this class, used when the assistant is unavailable or its answer is rejected.
  /// Skips what was already tried; empty means nothing safe is left.
  public func defaultRepair(after tried: [RepairOperation]) -> [RepairOperation] {
    let order: [RepairOperation] = switch self {
    case .network, .corruptFile: [.retryDownload]
    case .outOfMemory: [.reduceContext, .lowerQuantization]
    case .engineCrashed, .loadTimedOut: [.restartRuntime, .reduceContext]
    case .portInUse: [.restartRuntime]
    case .diskFull, .unrepairable: []
    }
    return order.first { !tried.contains($0) }.map { [$0] } ?? []
  }
}

/// A failure with everything private removed, safe to show an assistant model.
public struct FailureReport: Sendable, Equatable, Codable {
  public var step: String
  public var failureClass: FailureClass
  public var message: String
  public var logTail: String
  public var hardware: String
  public var triedAlready: [String]
  /// What the read-only probes the assistant asked for found, in order.
  public var findings: [String] = []

  public static let logLimit = 2000

  public static func make(
    _ failure: InstallFailure, hardware: String, tried: [RepairOperation], modelsRoot: URL
  ) -> FailureReport {
    FailureReport(
      step: failure.step.title, failureClass: .classify(failure),
      message: redact(failure.message, modelsRoot: modelsRoot),
      logTail: String(redact(failure.logTail ?? "", modelsRoot: modelsRoot).suffix(logLimit)),
      hardware: hardware, triedAlready: tried.map(\.name))
  }

  /// Removes keys, tokens and any path outside the models folder.
  static func redact(_ text: String, modelsRoot: URL) -> String {
    Redaction.clean(text, root: modelsRoot, label: "<models>")
  }
}

/// Removes keys, tokens and private paths from text that is logged or shown to an assistant.
public enum Redaction {
  public static func clean(_ text: String, root: URL, label: String) -> String {
    var out = text.replacingOccurrences(of: root.path, with: label)
    let rules: [(String, String)] = [
      (#"(?i)(bearer|api[-_ ]?key)[=: ]+\S+"#, "$1 <secret>"),
      (#"\b(sk|hf|ghp|gho)[-_][A-Za-z0-9_\-]{8,}"#, "<secret>"),
      (#"(?<![\w<])/(Users|home|private|var|tmp|Volumes|Library|opt|etc)/[^\s'"):,]+"#, "<path>"),
    ]
    for (pattern, template) in rules {
      out = out.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
    return out
  }
}

/// An assistant's answer: an explanation and operations from the catalogue, nothing else.
public struct RepairProposal: Sendable, Equatable {
  public var explanation: String
  public var operations: [RepairOperation]
  /// Web pages the assistant relied on (https only, at most 3), shown with the repair.
  public var references: [String] = []

  public enum Invalid: Error, Equatable, CustomStringConvertible {
    case notJSON, unknownOperation(String), tooMany, badModel(String), empty, badValue(String)

    public var description: String {
      switch self {
      case .notJSON: "The answer was not the expected JSON."
      case .unknownOperation(let name): "'\(name)' is not a repair operation."
      case .tooMany: "The answer proposed too many operations."
      case .badModel(let id): "'\(id)' is not an installed model that may be removed."
      case .empty: "The answer proposed nothing."
      case .badValue(let name): "'\(name)' needs a value the planner offers."
      }
    }
  }

  public static let maxOperations = 3
  public static let maxExplanation = 600

  private struct Raw: Decodable {
    struct Op: Decodable { var op: String; var modelId: String?; var to: String? }
    var explanation: String
    var operations: [Op]?
    var probe: String?
    var references: [String]?
  }

  /// Parses an assistant reply. `removable` is the installed models it may name for `freeDisk`.
  public static func parse(_ json: String, removable: Set<String>) throws -> RepairProposal {
    guard let raw = try? JSONDecoder().decode(Raw.self, from: Data(json.utf8)) else { throw Invalid.notJSON }
    let listed = raw.operations ?? []
    guard !listed.isEmpty else { throw Invalid.empty }
    guard listed.count <= maxOperations else { throw Invalid.tooMany }
    let operations = try listed.map { entry -> RepairOperation in
      switch entry.op {
      case "retryDownload": return .retryDownload
      case "lowerQuantization": return .lowerQuantization
      case "reduceContext": return .reduceContext
      case "restartRuntime": return .restartRuntime
      case "cancelAndCleanUp": return .cancelAndCleanUp
      case "useMirror":
        guard let host = entry.to, RepairOperation.mirrors.contains(host) else { throw Invalid.badValue("useMirror") }
        return .useMirror(host)
      case "setContext":
        guard let text = entry.to, let size = Int(text), ModelPlanner.contexts.contains(size) else {
          throw Invalid.badValue("setContext")
        }
        return .setContext(size)
      case "setQuantization":
        guard let text = entry.to, let quant = Quantization(rawValue: text) else { throw Invalid.badValue("setQuantization") }
        return .setQuantization(quant)
      case "freeDisk":
        guard let id = entry.modelId, removable.contains(id) else { throw Invalid.badModel(entry.modelId ?? "") }
        return .freeDisk(modelId: id)
      default: throw Invalid.unknownOperation(String(entry.op.prefix(40)))
      }
    }
    let references = (raw.references ?? []).filter { $0.hasPrefix("https://") && $0.count <= 300 }.prefix(3)
    return RepairProposal(
      explanation: String(raw.explanation.prefix(maxExplanation)), operations: operations, references: Array(references))
  }
}

/// A read-only look at this Mac that the assistant may ask for before deciding. Fixed code runs each one.
public enum RepairProbe: String, Sendable, CaseIterable {
  case diskFree, modelsFolder, memory, network

  /// `source` is the download server the install is actually using.
  public func run(store: ModelStore, hardware: String, source: String) async -> String {
    switch self {
    case .diskFree:
      let free = (try? HardwareProbe.current(modelsDirectory: store.root).freeDiskBytes) ?? 0
      return "Free disk: \(ModelPlanner.gb(free))."
    case .modelsFolder:
      let ids = (try? FileManager.default.contentsOfDirectory(atPath: store.root.path)) ?? []
      let lines = ids.sorted().prefix(20).map { id -> String in
        let files = (try? FileManager.default.contentsOfDirectory(atPath: store.folder(id).path)) ?? []
        let bytes = files.reduce(UInt64(0)) { total, name in
          let size = (try? FileManager.default.attributesOfItem(atPath: store.folder(id).appendingPathComponent(name).path)[.size] as? UInt64) ?? 0
          return total + size
        }
        return "\(id): \(files.count) files, \(ModelPlanner.gb(bytes))" + (files.contains { $0.hasSuffix(".part") } ? ", has a partial download" : "")
      }
      return lines.isEmpty ? "The models folder is empty." : lines.joined(separator: "\n")
    case .memory:
      return "\(hardware). Memory in use by other programs is not measured."
    case .network:
      guard let url = URL(string: source) else { return "The download source is not a valid address." }
      var request = URLRequest(url: url, timeoutInterval: 6)
      request.httpMethod = "HEAD"
      do {
        let (_, response) = try await URLSession.shared.data(for: request)
        return "The download server \(url.host ?? source) answered HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)."
      } catch {
        return "The download server \(url.host ?? source) could not be reached: \(error.localizedDescription)"
      }
    }
  }
}

/// What an assistant answered: a probe to run first, or the repairs to apply.
public enum RepairReply: Sendable, Equatable {
  case probe(RepairProbe)
  /// A command to run in the models folder, after the rules and the user agree.
  case command(String)
  /// A question to look up on the web.
  case search(String)
  case proposal(RepairProposal)

  public static func parse(_ json: String, removable: Set<String>) throws -> RepairReply {
    struct Peek: Decodable { var probe: String?; var command: String?; var search: String? }
    if let query = (try? JSONDecoder().decode(Peek.self, from: Data(json.utf8)))?.search {
      guard !query.isEmpty, query.count <= 200 else { throw RepairProposal.Invalid.badValue("search") }
      return .search(query)
    }
    if let command = (try? JSONDecoder().decode(Peek.self, from: Data(json.utf8)))?.command {
      guard !command.isEmpty, command.count <= 300 else { throw RepairProposal.Invalid.badValue("command") }
      return .command(command)
    }
    if let name = (try? JSONDecoder().decode(Peek.self, from: Data(json.utf8)))?.probe {
      guard let probe = RepairProbe(rawValue: name) else { throw RepairProposal.Invalid.unknownOperation(String(name.prefix(40))) }
      return .probe(probe)
    }
    return .proposal(try RepairProposal.parse(json, removable: removable))
  }
}

/// Explains a failure and proposes repairs. May be a bundled model or the user's own API provider;
/// its reply is untrusted text that `RepairProposal.parse` checks before anything runs.
public protocol RepairAssistant: Sendable {
  func propose(for report: FailureReport, removable: [String]) async throws -> String
  /// Looks something up on the web. The answer includes its sources. Assistants without search say so.
  func search(_ query: String) async throws -> String
}

extension RepairAssistant {
  public func search(_ query: String) async throws -> String { "Web search is not available." }
}
