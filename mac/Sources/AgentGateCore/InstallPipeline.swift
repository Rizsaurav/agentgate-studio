import Foundation

/// The steps the user watches, in order.
public enum InstallStep: Int, CaseIterable, Sendable, Codable, Comparable {
  case hardware, compatibility, quantization, download, configure, load, test, ready

  public var title: String {
    switch self {
    case .hardware: "Hardware"
    case .compatibility: "Compatibility"
    case .quantization: "Quantization"
    case .download: "Download"
    case .configure: "Configure"
    case .load: "Load"
    case .test: "Test"
    case .ready: "Ready"
    }
  }

  public static func < (a: InstallStep, b: InstallStep) -> Bool { a.rawValue < b.rawValue }
}

public struct InstallUpdate: Sendable, Equatable {
  public var step: InstallStep
  public var message: String
  public var completedBytes: UInt64 = 0
  public var totalBytes: UInt64 = 0

  public init(step: InstallStep, message: String, completedBytes: UInt64 = 0, totalBytes: UInt64 = 0) {
    self.step = step
    self.message = message
    self.completedBytes = completedBytes
    self.totalBytes = totalBytes
  }
}

/// A failed install: where it stopped and why, for the user and the repair assistant.
public struct InstallFailure: Error, Sendable, CustomStringConvertible {
  public var step: InstallStep
  public var message: String
  /// The underlying error, kept so a repair can match on it.
  public var cause: any Error & Sendable
  /// The engine's last output, when the engine was involved.
  public var logTail: String?

  public var description: String { message }

  public init(step: InstallStep, message: String, cause: any Error & Sendable, logTail: String?) {
    self.step = step
    self.message = message
    self.cause = cause
    self.logTail = logTail
  }
}

/// Runs the whole install for one model: hardware → compatibility → quantization → download →
/// configure → load → test → ready. Leaves the model loaded and returns its engine.
public struct InstallPipeline: Sendable {
  public var store = ModelStore()
  public var downloader = Downloader()
  public var verifier = ModelVerifier()
  public var binaries = LlamaRuntime.binaryDirectory()

  /// What this build can install: ready-made GGUF files on the bundled llama.cpp.
  public static let supported = ModelPlanner.Limits(budget: nil, lowestQuant: .q3_K_M, allowLocalQuantization: false)

  public init() {}

  public func install(
    _ model: CatalogModel, limits: ModelPlanner.Limits = supported,
    update: @escaping @Sendable (InstallUpdate) -> Void
  ) async throws -> (InstalledModel, LlamaRuntime) {
    func at<T>(_ step: InstallStep, _ message: String, _ body: () async throws -> T) async throws -> T {
      update(InstallUpdate(step: step, message: message))
      do {
        return try await body()
      } catch let failure as InstallFailure {
        throw failure
      } catch {
        throw InstallFailure(step: step, message: String(describing: error), cause: error as any Error & Sendable, logTail: nil)
      }
    }

    let profile = try await at(.hardware, "Reading this Mac's chip, memory and disk…") {
      try HardwareProbe.current(modelsDirectory: store.root)
    }
    let plan = try await at(.compatibility, "\(profile.summary). Checking \(model.name) fits…") {
      switch ModelPlanner.plan(model, for: profile, limits: limits) {
      case .compatible(let plan): return plan
      case .incompatible(let reason): throw PlanError.incompatible(reason)
      }
    }
    let file = try await at(.quantization, plan.reason) { () -> CatalogModel.GGUFFile in
      guard case .ggufFile(_, let file) = plan.source else { throw PlanError.unsupportedSource }
      return file
    }

    let destination = store.folder(model.id).appendingPathComponent(file.file)
    try await at(.download, "Downloading \(file.file)…") {
      let url = URL(string: "https://huggingface.co/\(model.gguf.repo)/resolve/main/\(file.file)")!
      if FileManager.default.fileExists(atPath: destination.path),
         try Downloader.sha256(of: destination) == file.sha256 {
        return
      }
      try await downloader.download(from: url, to: destination, bytes: file.bytes, sha256: file.sha256) { p in
        update(InstallUpdate(
          step: .download,
          message: "Downloading \(ModelPlanner.gb(p.completedBytes)) of \(ModelPlanner.gb(p.totalBytes))"
            + (p.attempt > 1 ? " (resumed)" : ""),
          completedBytes: p.completedBytes, totalBytes: p.totalBytes))
      }
    }

    let config = try await at(.configure, "\(plan.context / 1024)K context, all layers on the GPU, q8_0 KV cache.") {
      RuntimeConfig.for(plan, profile: profile)
    }
    let runtime = try await at(.load, "Loading \(model.name) into memory…") {
      do {
        return try await LlamaRuntime.start(model: destination, alias: model.id, config: config, binaries: binaries)
      } catch let error as RuntimeError {
        throw InstallFailure(step: .load, message: error.description, cause: error, logTail: Self.logTail(error))
      }
    }

    do {
      let readiness = try await at(.test, "Asking for a short reply, then a tool call…") {
        let result = try await verifier.verify(baseURL: runtime.baseURL, apiKey: runtime.apiKey, model: model.id)
        if runtime.outOfMemory { throw RuntimeError.outOfMemory }
        // A model the catalog marks as without tools is never offered for agent sessions.
        return model.toolCalling ? result : .chatOnly
      }
      let installed = InstalledModel(
        id: model.id, name: model.name, quant: plan.quant, file: file.file, sha256: file.sha256,
        bytes: file.bytes, backend: plan.backend, config: config, readiness: readiness,
        reason: plan.reason, verifiedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
      try await at(.ready, readiness == .ready ? "Ready for agent sessions." : "Ready to chat. It cannot call tools.") {
        try store.save(installed)
      }
      return (installed, runtime)
    } catch let failure as InstallFailure {
      let tail = runtime.logTail
      runtime.stop()
      var failure = failure
      failure.logTail = failure.logTail ?? tail
      throw failure
    }
  }

  /// Loads a model that is already installed, with the configuration it was verified with.
  public func load(
    _ model: InstalledModel, update: @escaping @Sendable (InstallUpdate) -> Void
  ) async throws -> LlamaRuntime {
    update(InstallUpdate(step: .load, message: "Loading \(model.name) into memory…"))
    do {
      let runtime = try await LlamaRuntime.start(
        model: store.fileURL(model), alias: model.id, config: model.config, binaries: binaries)
      update(InstallUpdate(step: .ready, message: "\(model.name) is loaded."))
      return runtime
    } catch let error as RuntimeError {
      throw InstallFailure(step: .load, message: error.description, cause: error, logTail: Self.logTail(error))
    }
  }

  static func logTail(_ error: RuntimeError) -> String? {
    if case .exited(_, let tail) = error { tail } else { nil }
  }
}

public enum PlanError: Error, Equatable, CustomStringConvertible {
  case incompatible(String)
  case unsupportedSource

  public var description: String {
    switch self {
    case .incompatible(let reason): "This model does not fit this Mac. \(reason)"
    case .unsupportedSource: "This install needs local quantization or MLX, which this build does not run yet."
    }
  }
}
