import Foundation

/// One line of the audit log: what was proposed or done, why, and what came of it.
public struct AuditEntry: Codable, Sendable, Equatable {
  public enum Outcome: String, Codable, Sendable {
    case proposed, approved, denied, done, notApplicable, failed, rejected
  }

  public var date: Date
  public var modelId: String
  public var operation: String
  public var reason: String
  public var outcome: Outcome
}

/// Every proposed and executed repair, kept on this Mac (0600) and shown in the app. Bounded.
public struct AuditLog: Sendable {
  public static let limit = 500
  private static let lock = NSLock()
  public let file: URL

  public init(file: URL = AppPaths.support.appendingPathComponent("repair-audit.json")) { self.file = file }

  public func entries() -> [AuditEntry] {
    Self.lock.withLock { read() }
  }

  public func append(_ entry: AuditEntry) throws {
    try Self.lock.withLock {
      let entries = Array((read() + [entry]).suffix(Self.limit))
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      try encoder.encode(entries).write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
  }

  private func read() -> [AuditEntry] {
    guard let data = try? Data(contentsOf: file) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode([AuditEntry].self, from: data)) ?? []
  }
}

public enum RepairError: Error, Sendable, CustomStringConvertible {
  /// The install failed and no repair was possible, allowed or approved.
  case unrepaired(InstallFailure, why: String)

  public var description: String {
    switch self {
    case .unrepaired(let failure, let why): "\(failure.message) \(why)"
    }
  }
}

/// Installs a model and, when a step fails, repairs and retries using only catalogue operations.
/// At most `maxOperations` run per install. With no usable assistant answer it applies the fixed
/// default for the failure class, and when none applies it stops.
public struct RepairRunner: Sendable {
  public static let maxOperations = 8
  public static let maxProbes = 3

  public var pipeline = InstallPipeline()
  public var audit = AuditLog()
  public var assistant: (any RepairAssistant)?
  /// Asked before any repair that needs approval; `false` stops the install.
  public var approve: @Sendable (RepairOperation, FailureReport) async -> Bool

  public init(
    pipeline: InstallPipeline = InstallPipeline(), audit: AuditLog = AuditLog(),
    assistant: (any RepairAssistant)? = nil,
    approve: @escaping @Sendable (RepairOperation, FailureReport) async -> Bool
  ) {
    self.pipeline = pipeline
    self.audit = audit
    self.assistant = assistant
    self.approve = approve
  }

  public func install(
    _ model: CatalogModel, limits start: ModelPlanner.Limits = InstallPipeline.supported,
    update: @escaping @Sendable (InstallUpdate) -> Void
  ) async throws -> (InstalledModel, LlamaRuntime) {
    var limits = start
    var tried: [RepairOperation] = []
    while true {
      do {
        return try await pipeline.install(model, limits: limits, update: update)
      } catch let failure as InstallFailure {
        guard tried.count < Self.maxOperations else {
          throw RepairError.unrepaired(failure, why: "Stopped after \(Self.maxOperations) repair attempts.")
        }
        let hardware = (try? HardwareProbe.current(modelsDirectory: pipeline.store.root).summary) ?? "unknown"
        let report = FailureReport.make(failure, hardware: hardware, tried: tried, modelsRoot: pipeline.store.root)
        let proposal = try await propose(report, tried: tried, model: model)
        var applied = false
        for operation in proposal.operations where tried.count < Self.maxOperations {
          let reason = proposal.explanation
          try record(model, operation, reason, .proposed)
          if operation.needsApproval(downloadBytes: failure.plan?.downloadBytes ?? .max) {
            guard await approve(operation, report) else {
              try record(model, operation, reason, .denied)
              throw RepairError.unrepaired(failure, why: "The repair was not approved.")
            }
            try record(model, operation, reason, .approved)
          }
          tried.append(operation)
          do {
            guard try perform(operation, failure: failure, model: model, limits: &limits) else {
              try record(model, operation, "Does not apply here.", .notApplicable)
              continue
            }
            try record(model, operation, reason, .done)
            if operation == .cancelAndCleanUp {
              throw RepairError.unrepaired(failure, why: "Stopped and removed the incomplete files.")
            }
            applied = true
          } catch let error as RepairError {
            throw error
          } catch {
            try record(model, operation, String(describing: error), .failed)
            throw RepairError.unrepaired(failure, why: "The repair itself failed.")
          }
        }
        guard applied else { throw RepairError.unrepaired(failure, why: "No safe repair applies.") }
        update(InstallUpdate(step: failure.step, message: "Repaired. Trying again…"))
      }
    }
  }

  /// The assistant's validated answer, or the fixed default when there is none. The assistant may ask for
  /// read-only probes first (at most 3), each logged.
  private func propose(_ report: FailureReport, tried: [RepairOperation], model: CatalogModel) async throws -> RepairProposal {
    let removable = ((try? pipeline.store.list()) ?? []).map(\.id).filter { $0 != model.id }
    if let assistant {
      var report = report
      do {
        for _ in 0...Self.maxProbes {
          let reply = try await assistant.propose(for: report, removable: removable)
          switch try RepairReply.parse(reply, removable: Set(removable)) {
          case .proposal(let proposal): return proposal
          case .probe(let probe):
            guard report.findings.count < Self.maxProbes else { throw RepairProposal.Invalid.tooMany }
            let found = await probe.run(store: pipeline.store, hardware: report.hardware)
            try record(model, nil, "probe \(probe.rawValue): \(found.prefix(120))", .done)
            report.findings.append("\(probe.rawValue): \(found)")
          }
        }
      } catch {
        try record(model, nil, "Assistant answer not used: \(error)", .rejected)
      }
    }
    return RepairProposal(
      explanation: "Standard repair for a \(report.failureClass.rawValue) failure.",
      operations: report.failureClass.defaultRepair(after: tried))
  }

  /// Runs one operation. Returns false when it does not apply (nothing changed).
  private func perform(
    _ operation: RepairOperation, failure: InstallFailure, model: CatalogModel,
    limits: inout ModelPlanner.Limits
  ) throws -> Bool {
    switch operation {
    case .retryDownload, .restartRuntime:
      return true
    case .reduceContext:
      guard let current = failure.plan?.context, let next = ModelPlanner.contexts.first(where: { $0 < current }) else { return false }
      limits.maxContext = next
      return true
    case .setContext(let size):
      guard let current = failure.plan?.context, size < current else { return false }
      limits.maxContext = size
      return true
    case .setQuantization(let quant):
      guard let current = failure.plan?.quant, quant != current, !(quant < limits.lowestQuant) else { return false }
      limits.highestQuant = quant
      return true
    case .lowerQuantization:
      guard let current = failure.plan?.quant,
            let index = Quantization.allCases.firstIndex(of: current),
            index + 1 < Quantization.allCases.count else { return false }
      let next = Quantization.allCases[index + 1]
      guard !(next < limits.lowestQuant) else { return false }
      limits.highestQuant = next
      return true
    case .freeDisk(let id):
      guard id != model.id else { return false }
      try pipeline.store.remove(id)
      return true
    case .cancelAndCleanUp:
      // A finished install has a manifest; only an incomplete folder is removed.
      let folder = pipeline.store.folder(model.id)
      if (try? pipeline.store.load(model.id)) == nil, FileManager.default.fileExists(atPath: folder.path) {
        try FileManager.default.removeItem(at: folder)
      }
      return true
    }
  }

  /// Throws when the entry cannot be written: a repair that cannot be audited does not run.
  private func record(_ model: CatalogModel, _ operation: RepairOperation?, _ reason: String, _ outcome: AuditEntry.Outcome) throws {
    let entry = AuditEntry(
      date: Date(), modelId: model.id, operation: operation?.name ?? "none", reason: reason, outcome: outcome)
    try audit.append(entry)
  }
}
