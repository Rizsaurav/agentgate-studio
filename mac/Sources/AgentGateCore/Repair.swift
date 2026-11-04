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

  public var name: String {
    switch self {
    case .retryDownload: "retryDownload"
    case .lowerQuantization: "lowerQuantization"
    case .reduceContext: "reduceContext"
    case .restartRuntime: "restartRuntime"
    case .freeDisk: "freeDisk"
    case .cancelAndCleanUp: "cancelAndCleanUp"
    }
  }

  /// A repair that deletes files, changes the model's quality, or downloads over 1 GB is the user's call.
  public func needsApproval(downloadBytes: UInt64) -> Bool {
    switch self {
    case .freeDisk, .lowerQuantization: true
    case .retryDownload: downloadBytes > MemoryBudget.gib
    case .reduceContext, .restartRuntime, .cancelAndCleanUp: false
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
    var out = text.replacingOccurrences(of: modelsRoot.path, with: "<models>")
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
    case notJSON, unknownOperation(String), tooMany, badModel(String), empty

    public var description: String {
      switch self {
      case .notJSON: "The answer was not the expected JSON."
      case .unknownOperation(let name): "'\(name)' is not a repair operation."
      case .tooMany: "The answer proposed too many operations."
      case .badModel(let id): "'\(id)' is not an installed model that may be removed."
      case .empty: "The answer proposed nothing."
      }
    }
  }

  public static let maxOperations = 3
  public static let maxExplanation = 600

  private struct Raw: Decodable {
    struct Op: Decodable { var op: String; var modelId: String? }
    var explanation: String
    var operations: [Op]
  }

  /// Parses an assistant reply. `removable` is the installed models it may name for `freeDisk`.
  public static func parse(_ json: String, removable: Set<String>) throws -> RepairProposal {
    guard let raw = try? JSONDecoder().decode(Raw.self, from: Data(json.utf8)) else { throw Invalid.notJSON }
    guard !raw.operations.isEmpty else { throw Invalid.empty }
    guard raw.operations.count <= maxOperations else { throw Invalid.tooMany }
    let operations = try raw.operations.map { entry -> RepairOperation in
      switch entry.op {
      case "retryDownload": return .retryDownload
      case "lowerQuantization": return .lowerQuantization
      case "reduceContext": return .reduceContext
      case "restartRuntime": return .restartRuntime
      case "cancelAndCleanUp": return .cancelAndCleanUp
      case "freeDisk":
        guard let id = entry.modelId, removable.contains(id) else { throw Invalid.badModel(entry.modelId ?? "") }
        return .freeDisk(modelId: id)
      default: throw Invalid.unknownOperation(String(entry.op.prefix(40)))
      }
    }
    return RepairProposal(explanation: String(raw.explanation.prefix(maxExplanation)), operations: operations)
  }
}

/// Explains a failure and proposes repairs. May be a bundled model or the user's own API provider;
/// its reply is untrusted text that `RepairProposal.parse` checks before anything runs.
public protocol RepairAssistant: Sendable {
  func propose(for report: FailureReport, removable: [String]) async throws -> String
}
