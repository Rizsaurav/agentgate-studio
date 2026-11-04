import Foundation

/// What is installed for one model, written once the model has passed its checks.
public struct InstalledModel: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var name: String
  public var quant: Quantization
  public var file: String
  public var sha256: String
  public var bytes: UInt64
  public var backend: Backend
  public var config: RuntimeConfig
  public var readiness: Readiness
  public var reason: String
  public var verifiedAt: Date
}

/// Installed models on disk: one folder per model holding its files and `manifest.json`.
public struct ModelStore: Sendable {
  public let root: URL

  public init(root: URL = AppPaths.models) { self.root = root }

  public func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

  public func fileURL(_ model: InstalledModel) -> URL { folder(model.id).appendingPathComponent(model.file) }

  public func list() throws -> [InstalledModel] {
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .compactMap { try load($0.lastPathComponent) }
      .sorted { $0.name < $1.name }
  }

  /// The manifest for `id`, or nil when the model is not (fully) installed.
  public func load(_ id: String) throws -> InstalledModel? {
    let url = folder(id).appendingPathComponent("manifest.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let model = try decoder.decode(InstalledModel.self, from: Data(contentsOf: url))
    // A manifest whose model file is gone is not an installed model.
    return FileManager.default.fileExists(atPath: fileURL(model).path) ? model : nil
  }

  public func save(_ model: InstalledModel) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileManager.default.createDirectory(at: folder(model.id), withIntermediateDirectories: true)
    try encoder.encode(model).write(to: folder(model.id).appendingPathComponent("manifest.json"), options: .atomic)
  }

  public func remove(_ id: String) throws {
    guard id.wholeMatch(of: /[a-z0-9][a-z0-9.\-]{0,63}/) != nil else { throw CatalogError.invalid("bad model id") }
    if FileManager.default.fileExists(atPath: folder(id).path) { try FileManager.default.removeItem(at: folder(id)) }
  }
}
