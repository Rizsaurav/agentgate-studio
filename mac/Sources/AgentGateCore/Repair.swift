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
  /// A shell command the assistant wants run to look at something. It is never a repair on its own:
  /// the same rules as the agent's terminal apply, the user approves it, and its output goes back to the assistant.
  case runCommand(String)

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
    }
  }

  /// A repair that deletes files, changes the model's quality, or downloads over 1 GB is the user's call.
  public func needsApproval(downloadBytes: UInt64) -> Bool {
    switch self {
    case .freeDisk, .lowerQuantization, .setQuantization, .runCommand: true
    case .retryDownload: downloadBytes > MemoryBudget.gib
    case .reduceContext, .restartRuntime, .cancelAndCleanUp, .setContext: false
    }
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
    return RepairProposal(explanation: String(raw.explanation.prefix(maxExplanation)), operations: operations)
  }
}

/// A read-only look at this Mac that the assistant may ask for before deciding. Fixed code runs each one.
public enum RepairProbe: String, Sendable, CaseIterable {
  case diskFree, modelsFolder, memory, network

  public func run(store: ModelStore, hardware: String) async -> String {
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
      var request = URLRequest(url: URL(string: "https://huggingface.co")!, timeoutInterval: 6)
      request.httpMethod = "HEAD"
      do {
        let (_, response) = try await URLSession.shared.data(for: request)
        return "huggingface.co answered HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)."
      } catch {
        return "huggingface.co could not be reached: \(error.localizedDescription)"
      }
    }
  }
}

/// What an assistant answered: a probe to run first, or the repairs to apply.
public enum RepairReply: Sendable, Equatable {
  case probe(RepairProbe)
  /// A command to run in the models folder, after the rules and the user agree.
  case command(String)
  case proposal(RepairProposal)

  public static func parse(_ json: String, removable: Set<String>) throws -> RepairReply {
    struct Peek: Decodable { var probe: String?; var command: String? }
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
}
