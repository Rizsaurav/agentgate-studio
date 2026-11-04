import Foundation

public enum Backend: String, Codable, Sendable {
  /// llama.cpp, bundled in the app.
  case llamaCpp
  /// Apple MLX, installed on first use.
  case mlx
}

/// Where the model files come from.
public enum ModelSource: Sendable, Equatable {
  case ggufFile(repo: String, file: CatalogModel.GGUFFile)
  case mlxRepo(CatalogModel.MLXVariant)
  /// Full weights are downloaded and quantized on this Mac.
  case quantizeLocally(repo: String, to: Quantization)
}

/// Everything the installer needs to set up one model on this Mac.
public struct ModelPlan: Sendable, Equatable {
  public var modelId: String
  public var quant: Quantization
  public var context: Int
  public var backend: Backend
  public var source: ModelSource
  /// Weights, KV cache and runtime buffers while loaded.
  public var memoryBytes: UInt64
  public var downloadBytes: UInt64
  /// Peak disk use during the install, including intermediate files.
  public var diskBytes: UInt64
  /// Why this plan was chosen, in plain words.
  public var reason: String
}

public enum Compatibility: Sendable, Equatable {
  case compatible(ModelPlan)
  case incompatible(reason: String)

  public var plan: ModelPlan? {
    if case .compatible(let plan) = self { plan } else { nil }
  }
}

/// Chooses quantization, context size, backend and source for a model on a given machine.
/// Pure: the same catalog entry and hardware profile always give the same plan.
public enum ModelPlanner {
  /// Contexts tried, largest first. Agent sessions need at least the smallest.
  public static let contexts = [32768, 16384, 8192]
  public static let preferredContext = 16384
  /// Free disk kept untouched after an install.
  public static let diskMargin: UInt64 = 2 * MemoryBudget.gib
  /// KV cache bytes per element: llama.cpp runs with a q8_0 cache, MLX with f16.
  static func kvBytesPerElement(_ backend: Backend) -> Double { backend == .llamaCpp ? 1.0625 : 2 }

  public static func kvCacheBytes(_ model: CatalogModel, context: Int, backend: Backend) -> UInt64 {
    let a = model.architecture
    let elements = 2 * Double(a.layers * a.kvHeads * a.headDim) * Double(context)
    return UInt64(elements * kvBytesPerElement(backend))
  }

  public static func memoryBytes(weights: UInt64, model: CatalogModel, context: Int, backend: Backend) -> UInt64 {
    let overhead = 400 * (1 << 20) + weights / 50
    return weights + kvCacheBytes(model, context: context, backend: backend) + UInt64(overhead)
  }

  /// What a plan may use. Picking a model by name allows everything; tiers are stricter.
  public struct Limits: Sendable {
    /// Memory the plan may use; nil means the machine's whole model budget.
    public var budget: UInt64?
    public var lowestQuant: Quantization
    public var allowLocalQuantization: Bool
    /// Best quality the plan may use; a repair lowers it after a failure at a higher level.
    public var highestQuant: Quantization?
    /// Largest context the plan may use; a repair lowers it after running out of memory.
    public var maxContext: Int?

    public static let any = Limits(budget: nil, lowestQuant: .q3_K_M, allowLocalQuantization: true)

    public init(
      budget: UInt64?, lowestQuant: Quantization, allowLocalQuantization: Bool,
      highestQuant: Quantization? = nil, maxContext: Int? = nil
    ) {
      self.budget = budget
      self.lowestQuant = lowestQuant
      self.allowLocalQuantization = allowLocalQuantization
      self.highestQuant = highestQuant
      self.maxContext = maxContext
    }
  }

  public static func plan(
    _ model: CatalogModel, for profile: HardwareProfile, prefer backend: Backend = .llamaCpp,
    limits: Limits = .any
  ) -> Compatibility {
    let budget = min(limits.budget ?? .max, profile.modelBudgetBytes)
    let usable = contexts.filter { $0 <= model.contextMax && $0 <= (limits.maxContext ?? .max) }
    guard let minimum = usable.last else { return .incompatible(reason: "Its context is too short for agent sessions.") }

    var candidates: [ModelPlan] = []
    if backend == .mlx, profile.architecture == .appleSilicon {
      candidates += Quantization.allCases.compactMap { quant in
        quant.mlxBits.flatMap(model.mlxVariant(bits:)).map { variant in
          ModelPlan(modelId: model.id, quant: quant, context: minimum, backend: .mlx, source: .mlxRepo(variant),
                    memoryBytes: 0, downloadBytes: variant.bytes, diskBytes: variant.bytes, reason: "")
        }
      }
    }
    // Ready-made files first, so a download is preferred over a long local quantization.
    candidates += model.gguf.files.map { file in
      ModelPlan(modelId: model.id, quant: file.quant, context: minimum, backend: .llamaCpp,
                source: .ggufFile(repo: model.gguf.repo, file: file),
                memoryBytes: 0, downloadBytes: file.bytes, diskBytes: file.bytes, reason: "")
    }
    if let source = model.source {
      for quant in Quantization.allCases where quant.canQuantizeLocally && model.file(quant) == nil {
        let output = UInt64(Double(source.bytes) * quant.bitsPerWeight / 16)
        candidates.append(ModelPlan(
          modelId: model.id, quant: quant, context: minimum, backend: .llamaCpp,
          source: .quantizeLocally(repo: source.repo, to: quant), memoryBytes: 0,
          downloadBytes: source.bytes, diskBytes: source.bytes * 2 + output, reason: ""))
      }
    }

    // Source kinds in order (MLX if asked for, ready-made, local). Within a kind: best quality at
    // the preferred context, then best quality at the minimum context.
    candidates.removeAll { plan in
      let local = if case .quantizeLocally = plan.source { true } else { false }
      return plan.quant < limits.lowestQuant || limits.highestQuant.map { plan.quant > $0 } == true
        || (local && !limits.allowLocalQuantization)
    }
    var diskNeeded: UInt64?
    let groups = Dictionary(grouping: candidates, by: { rank($0).kind }).sorted { $0.key < $1.key }
    for (_, group) in groups {
      for target in [min(preferredContext, usable[0]), minimum] {
        for var plan in group.sorted(by: { rank($0).quality < rank($1).quality }) {
          let weights = weightBytes(plan, model)
          guard memoryBytes(weights: weights, model: model, context: target, backend: plan.backend) <= budget else { continue }
          plan.context = usable.first {
            memoryBytes(weights: weights, model: model, context: $0, backend: plan.backend) <= budget
          } ?? target
          plan.memoryBytes = memoryBytes(weights: weights, model: model, context: plan.context, backend: plan.backend)
          guard plan.diskBytes + diskMargin <= profile.freeDiskBytes else {
            diskNeeded = min(diskNeeded ?? .max, plan.diskBytes + diskMargin)
            continue
          }
          plan.reason = reason(plan, budget: budget)
          return .compatible(plan)
        }
      }
    }

    if let diskNeeded {
      return .incompatible(reason: "Needs \(gb(diskNeeded)) of free disk; \(gb(profile.freeDiskBytes)) is free.")
    }
    let smallest = candidates.map { memoryBytes(weights: weightBytes($0, model), model: model, context: minimum, backend: $0.backend) }.min() ?? 0
    return .incompatible(reason: "Needs \(gb(smallest)) of memory for a model; this Mac has \(gb(budget)).")
  }

  /// Picks one model per tier: the first candidate whose ready-made file at Q4_K_M or better fits
  /// the tier's share of the memory budget. Small Macs fall back to the smallest candidate that fits
  /// at all, then to lower quality or local quantization. A tier is absent when nothing fits.
  public static func tiers(_ catalog: Catalog, for profile: HardwareProfile) -> [Tier: ModelPlan] {
    let strict = Limits(budget: nil, lowestQuant: .q4_K_M, allowLocalQuantization: false)
    var result: [Tier: ModelPlan] = [:]
    for tier in Tier.allCases {
      guard let rule = catalog.tiers[tier] else { continue }
      let models = rule.candidates.compactMap(catalog.model)
      func plans(_ limits: Limits) -> [ModelPlan] { models.compactMap { plan($0, for: profile, limits: limits).plan } }
      var share = strict
      share.budget = UInt64(Double(profile.modelBudgetBytes) * rule.share)
      result[tier] = plans(share).first
        ?? plans(strict).min { $0.memoryBytes < $1.memoryBytes }
        ?? plans(.any).min { $0.memoryBytes < $1.memoryBytes }
    }
    return result
  }

  /// Kind: MLX (only present when asked for), then ready-made, then local. Quality: best first.
  static func rank(_ plan: ModelPlan) -> (kind: Int, quality: Int) {
    let local = if case .quantizeLocally = plan.source { true } else { false }
    let kind = plan.backend == .mlx ? 0 : local ? 2 : 1
    return (kind, Quantization.allCases.firstIndex(of: plan.quant)!)
  }

  static func weightBytes(_ plan: ModelPlan, _ model: CatalogModel) -> UInt64 {
    switch plan.source {
    case .ggufFile(_, let file): file.bytes
    case .mlxRepo(let variant): variant.bytes
    case .quantizeLocally(_, let quant): UInt64(Double(model.source?.bytes ?? 0) * quant.bitsPerWeight / 16)
    }
  }

  static func reason(_ plan: ModelPlan, budget: UInt64) -> String {
    let fit = "\(plan.quant.rawValue) with a \(plan.context / 1024)K context: the best quality that fits the \(gb(budget)) this Mac has for a model."
    switch plan.source {
    case .quantizeLocally: return fit + " No ready-made file exists at this level, so it is quantized on this Mac."
    case .mlxRepo: return fit + " Runs on MLX, Apple's engine for M-series chips."
    case .ggufFile: return fit
    }
  }

  public static func gb(_ bytes: UInt64) -> String {
    String(format: "%.1f GB", Double(bytes) / Double(MemoryBudget.gib))
  }
}
