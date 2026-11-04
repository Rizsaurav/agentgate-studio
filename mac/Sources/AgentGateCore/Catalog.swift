import Foundation

/// A quantization level, best quality first. The order is the order the planner tries them in.
public enum Quantization: String, Codable, CaseIterable, Sendable, Comparable {
  case q8_0 = "Q8_0"
  case q6_K = "Q6_K"
  case q5_K_M = "Q5_K_M"
  case mxfp4 = "MXFP4"
  case q4_K_M = "Q4_K_M"
  case q3_K_M = "Q3_K_M"

  /// Average bits per weight, used to estimate a file that has to be quantized locally.
  public var bitsPerWeight: Double {
    switch self {
    case .q8_0: 8.5
    case .q6_K: 6.56
    case .q5_K_M: 5.69
    case .mxfp4: 4.25
    case .q4_K_M: 4.85
    case .q3_K_M: 3.91
    }
  }

  /// MXFP4 is a format models ship in, not one llama.cpp quantizes to.
  public var canQuantizeLocally: Bool { self != .mxfp4 }

  /// The MLX variant of the same quality class, if one exists.
  public var mlxBits: Int? {
    switch self {
    case .q8_0: 8
    case .q6_K: 6
    case .q4_K_M: 4
    default: nil
    }
  }

  public static func < (a: Quantization, b: Quantization) -> Bool {
    allCases.firstIndex(of: a)! > allCases.firstIndex(of: b)!
  }
}

public enum Tier: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable {
  case fast, balanced, smart

  public var label: String { rawValue.capitalized }
}

public struct TierRule: Codable, Sendable, Equatable {
  /// Share of the memory budget this tier may use, in (0, 1].
  public var share: Double
  /// Catalog ids, most preferred first.
  public var candidates: [String]
}

public struct CatalogModel: Codable, Sendable, Equatable, Identifiable {
  public struct Architecture: Codable, Sendable, Equatable {
    public var layers: Int
    public var kvHeads: Int
    public var headDim: Int
  }

  public struct GGUFFile: Codable, Sendable, Equatable {
    public var quant: Quantization
    public var file: String
    public var bytes: UInt64
    public var sha256: String
  }

  public struct GGUF: Codable, Sendable, Equatable {
    public var repo: String
    public var files: [GGUFFile]
  }

  /// Full-precision weights, used when no ready-made file exists at the chosen level.
  public struct Source: Codable, Sendable, Equatable {
    public var repo: String
    public var bytes: UInt64
  }

  public struct MLXVariant: Codable, Sendable, Equatable {
    public var bits: Int
    public var repo: String
    public var bytes: UInt64
  }

  public var id: String
  public var name: String
  public var publisher: String
  public var licence: String
  public var toolCalling: Bool
  public var contextMax: Int
  public var architecture: Architecture
  public var gguf: GGUF
  public var source: Source?
  public var mlx: [MLXVariant]?

  public func file(_ quant: Quantization) -> GGUFFile? { gguf.files.first { $0.quant == quant } }
  public func mlxVariant(bits: Int) -> MLXVariant? { mlx?.first { $0.bits == bits } }
}

public enum CatalogError: Error, Equatable, CustomStringConvertible {
  case invalid(String)

  public var description: String {
    switch self {
    case .invalid(let reason): "The model catalog is invalid: \(reason)"
    }
  }
}

/// The list of models AGENTGATE can install, validated before anything uses it.
public struct Catalog: Codable, Sendable, Equatable {
  public static let supportedVersion = 1

  public var version: Int
  public var tiers: [Tier: TierRule]
  public var models: [CatalogModel]

  public func model(_ id: String) -> CatalogModel? { models.first { $0.id == id } }

  /// Decodes and validates catalog JSON. Anything malformed is rejected as a whole.
  public static func decode(_ data: Data) throws -> Catalog {
    let catalog: Catalog
    do {
      catalog = try JSONDecoder().decode(Catalog.self, from: data)
    } catch {
      throw CatalogError.invalid("it is not valid catalog JSON (\(error.localizedDescription))")
    }
    try catalog.validate()
    return catalog
  }

  /// The copy shipped inside the app, used when the published catalog cannot be fetched.
  public static func bundled() throws -> Catalog {
    guard let url = Bundle.module.url(forResource: "catalog", withExtension: "json") else {
      throw CatalogError.invalid("the bundled catalog is missing")
    }
    return try decode(try Data(contentsOf: url))
  }

  func validate() throws {
    func fail(_ reason: String) -> CatalogError { .invalid(reason) }
    guard version == Self.supportedVersion else { throw fail("unsupported version \(version)") }
    guard !models.isEmpty else { throw fail("it lists no models") }
    var seen = Set<String>()
    for model in models {
      guard model.id.wholeMatch(of: /[a-z0-9][a-z0-9.\-]{0,63}/) != nil else {
        throw fail("bad model id \"\(model.id)\"")
      }
      guard seen.insert(model.id).inserted else { throw fail("duplicate model id \(model.id)") }
      guard !model.name.isEmpty, model.contextMax >= 2048 else { throw fail("\(model.id) has a bad name or context") }
      let a = model.architecture
      guard a.layers > 0, a.kvHeads > 0, a.headDim > 0 else { throw fail("\(model.id) has a bad architecture") }
      try Self.checkRepo(model.gguf.repo, model.id)
      guard !model.gguf.files.isEmpty || model.source != nil else {
        throw fail("\(model.id) has neither a ready-made file nor full weights")
      }
      for file in model.gguf.files {
        guard file.file.hasSuffix(".gguf"), !file.file.contains("/"), !file.file.contains("..") else {
          throw fail("\(model.id) has a bad file name")
        }
        guard file.bytes > 0, file.sha256.wholeMatch(of: /[0-9a-f]{64}/) != nil else {
          throw fail("\(model.id) \(file.quant.rawValue) has a bad size or checksum")
        }
      }
      if let source = model.source {
        try Self.checkRepo(source.repo, model.id)
        guard source.bytes > 0 else { throw fail("\(model.id) has a bad source size") }
      }
      for variant in model.mlx ?? [] {
        try Self.checkRepo(variant.repo, model.id)
        guard [4, 6, 8].contains(variant.bits), variant.bytes > 0 else { throw fail("\(model.id) has a bad MLX variant") }
      }
    }
    for tier in Tier.allCases {
      guard let rule = tiers[tier] else { throw fail("tier \(tier.rawValue) is missing") }
      guard rule.share > 0, rule.share <= 1, !rule.candidates.isEmpty else { throw fail("tier \(tier.rawValue) is malformed") }
      for id in rule.candidates where !seen.contains(id) {
        throw fail("tier \(tier.rawValue) names unknown model \(id)")
      }
    }
  }

  static func checkRepo(_ repo: String, _ id: String) throws {
    guard repo.wholeMatch(of: /[A-Za-z0-9_.\-]+\/[A-Za-z0-9_.\-]+/) != nil, !repo.contains("..") else {
      throw CatalogError.invalid("\(id) has a bad repository name")
    }
  }
}
