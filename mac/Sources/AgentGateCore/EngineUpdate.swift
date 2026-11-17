import CryptoKit
import Foundation

/// The two programs the app runs that are not its own: the model engine and the agent harness.
public enum EngineKind: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable {
  case llama
  case opencode

  public var label: String { self == .llama ? "llama.cpp" : "OpenCode" }
  /// The program inside a release, whose folder is the engine directory.
  public var binary: String { self == .llama ? "llama-server" : "opencode" }
}

/// One pinned release: where it is and what it must hash to.
public struct EnginePin: Codable, Sendable, Equatable {
  public var tag: String
  public var url: URL
  public var sha256: String

  public init(tag: String, url: URL, sha256: String) {
    self.tag = tag
    self.url = url
    self.sha256 = sha256
  }
}

/// `engines.json`: the pinned versions and checksums, in one place for the build scripts, CI and the app.
public struct EngineManifest: Codable, Sendable, Equatable {
  public static let supportedVersion = 1
  /// Where the released app looks for newer pins: the manifest on the released branch.
  public static let publishedURL = URL(string: "https://raw.githubusercontent.com/Rizsaurav/agentgate-studio/main/mac/Sources/AgentGateCore/Resources/engines.json")!

  public var version: Int
  public var engines: [EngineKind: EnginePin]

  public static func decode(_ data: Data) throws -> EngineManifest {
    let manifest: EngineManifest
    do { manifest = try JSONDecoder().decode(EngineManifest.self, from: data) }
    catch { throw EngineUpdateError.invalidManifest("it is not valid JSON for engines (\(error.localizedDescription))") }
    guard manifest.version == supportedVersion else { throw EngineUpdateError.invalidManifest("unsupported version \(manifest.version)") }
    for kind in EngineKind.allCases {
      guard let pin = manifest.engines[kind] else { throw EngineUpdateError.invalidManifest("\(kind.label) is missing") }
      // Releases come only from GitHub over https, and the checksum is a full SHA-256.
      guard pin.url.scheme == "https", pin.url.host == "github.com", pin.url.path.contains("/releases/download/"),
            pin.tag.wholeMatch(of: /[A-Za-z0-9._\-]{1,40}/) != nil, pin.url.path.contains("/\(pin.tag)/"),
            pin.sha256.wholeMatch(of: /[0-9a-f]{64}/) != nil,
            pin.url.lastPathComponent.hasSuffix(".tar.gz") || pin.url.lastPathComponent.hasSuffix(".zip") else {
        throw EngineUpdateError.invalidManifest("\(kind.label) has a bad tag, URL or checksum")
      }
    }
    return manifest
  }

  public static func bundled() throws -> EngineManifest {
    guard let url = Bundle.module.url(forResource: "engines", withExtension: "json") else {
      throw EngineUpdateError.invalidManifest("the bundled engines.json is missing")
    }
    return try decode(try Data(contentsOf: url))
  }
}

public enum EngineUpdateError: Error, Equatable, CustomStringConvertible {
  case invalidManifest(String)
  case checksumMismatch(EngineKind)
  case binaryMissing(EngineKind)
  case trialFailed(EngineKind, String)
  case nothingToRollBack(EngineKind)
  case unpackFailed(String)

  public var description: String {
    switch self {
    case .invalidManifest(let why): "The engine list is invalid: \(why)."
    case .checksumMismatch(let kind): "The \(kind.label) download did not match its pinned checksum, so it was deleted. Nothing changed."
    case .binaryMissing(let kind): "The \(kind.label) download does not contain \(kind.binary). Nothing changed."
    case .trialFailed(let kind, let why): "The new \(kind.label) failed its check (\(why)). It was removed and the current version stays."
    case .nothingToRollBack(let kind): "There is no previous \(kind.label) to go back to."
    case .unpackFailed(let why): "The download could not be unpacked (\(why)). Nothing changed."
    }
  }
}

/// Engine versions installed by updates, kept beside the app's own bundled copy:
/// `<root>/<kind>/<tag>/` and `state.json` with the active and previous tag of each kind.
/// Never touches models or projects.
public struct EngineStore: Sendable {
  public struct Slot: Codable, Sendable, Equatable {
    public var active: String?
    public var previous: String?
  }

  public let root: URL

  public init(root: URL = AppPaths.support.appendingPathComponent("runtimes", isDirectory: true)) { self.root = root }

  public func folder(_ kind: EngineKind, _ tag: String) -> URL {
    root.appendingPathComponent(kind.rawValue, isDirectory: true).appendingPathComponent(tag, isDirectory: true)
  }

  public func state() throws -> [EngineKind: Slot] {
    let url = root.appendingPathComponent("state.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
    return try JSONDecoder().decode([EngineKind: Slot].self, from: Data(contentsOf: url))
  }

  func save(_ state: [EngineKind: Slot]) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(state).write(to: root.appendingPathComponent("state.json"), options: .atomic)
  }

  /// The updated engine to use, or nil to use the bundled one. An unreadable state file or an active
  /// version whose program is missing falls back to the bundled engine on purpose: a damaged update
  /// must never leave the app without an engine. The next update or roll-back rewrites the state.
  public func activeDirectory(_ kind: EngineKind) -> URL? {
    guard let tag = (try? state())?[kind]?.active else { return nil }
    let dir = folder(kind, tag)
    return FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent(kind.binary).path) ? dir : nil
  }

  /// Makes `tag` active and keeps the one it replaces as the way back. Older versions are deleted.
  func activate(_ kind: EngineKind, _ tag: String) throws {
    var all = try state()
    let old = all[kind]?.active
    if let stale = all[kind]?.previous, stale != tag, stale != old {
      try? FileManager.default.removeItem(at: folder(kind, stale))
    }
    all[kind] = Slot(active: tag, previous: old)
    try save(all)
  }

  /// Goes back to the previous version: the bundled one when the update was the first.
  public func rollBack(_ kind: EngineKind) throws {
    var all = try state()
    guard let slot = all[kind], let current = slot.active else { throw EngineUpdateError.nothingToRollBack(kind) }
    all[kind] = Slot(active: slot.previous, previous: nil)
    try save(all)
    try? FileManager.default.removeItem(at: folder(kind, current))
  }
}

/// Installs a pinned engine release as a user-approved step: download, verify, unpack, then a trial
/// with the new version. It becomes active only when the trial passes; otherwise it is deleted and
/// the current version stays.
public struct EngineUpdater: Sendable {
  public typealias Download = @Sendable (URL) async throws -> URL
  public typealias Trial = @Sendable (URL) async throws -> Void

  public var store: EngineStore
  /// Fetches a URL to a local file. URLSession by default; tests use a local file.
  public var download: Download

  public init(store: EngineStore = EngineStore(), download: @escaping Download = EngineUpdater.urlSessionDownload) {
    self.store = store
    self.download = download
  }

  public static let urlSessionDownload: Download = { url in
    let (file, response) = try await URLSession.shared.download(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw EngineUpdateError.unpackFailed("the server answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
    }
    return file
  }

  /// The tag in use: an update if one is active, otherwise the bundled copy's (`.tag`, written by the fetch scripts).
  public func currentTag(_ kind: EngineKind, bundled: URL?) -> String? {
    if let tag = (try? store.state())?[kind]?.active, store.activeDirectory(kind) != nil { return tag }
    guard let bundled else { return nil }
    return (try? String(contentsOf: bundled.appendingPathComponent(".tag"), encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Pins in `published` that differ from what is in use.
  public func available(_ published: EngineManifest, bundled: [EngineKind: URL?]) -> [EngineKind: EnginePin] {
    published.engines.filter { kind, pin in currentTag(kind, bundled: bundled[kind] ?? nil) != pin.tag }
  }

  public func install(_ kind: EngineKind, _ pin: EnginePin, trial: Trial) async throws {
    let archive = try await download(pin.url)
    defer { try? FileManager.default.removeItem(at: archive) }
    guard try Self.sha256(of: archive) == pin.sha256 else { throw EngineUpdateError.checksumMismatch(kind) }

    let staging = store.root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try Self.unpack(archive, named: pin.url.lastPathComponent, into: staging)
    guard let binaryFolder = Self.find(kind.binary, in: staging) else { throw EngineUpdateError.binaryMissing(kind) }

    let target = store.folder(kind, pin.tag)
    // Reinstalling the active version is a no-op rather than deleting what is running.
    if (try store.state())[kind]?.active == pin.tag, store.activeDirectory(kind) != nil { return }
    try? FileManager.default.removeItem(at: target)
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: binaryFolder, to: target)
    try pin.tag.write(to: target.appendingPathComponent(".tag"), atomically: true, encoding: .utf8)
    do {
      try await trial(target)
    } catch {
      try? FileManager.default.removeItem(at: target)
      throw EngineUpdateError.trialFailed(kind, String(describing: error))
    }
    try store.activate(kind, pin.tag)
  }

  static func sha256(of file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  static func unpack(_ archive: URL, named name: String, into folder: URL) throws {
    let process = Process()
    if name.hasSuffix(".zip") {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
      process.arguments = ["-x", "-k", archive.path, folder.path]
    } else {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
      process.arguments = ["-xzf", archive.path, "-C", folder.path]
    }
    let errors = Pipe()
    process.standardError = errors
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      throw EngineUpdateError.unpackFailed(String(text.prefix(200)))
    }
  }

  /// The folder holding `binary` somewhere under `root`, without following links out of it.
  static func find(_ binary: String, in root: URL) -> URL? {
    let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
    while let url = items?.nextObject() as? URL {
      if url.lastPathComponent == binary, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
         FileManager.default.isExecutableFile(atPath: url.path) {
        return url.deletingLastPathComponent()
      }
    }
    return nil
  }
}

/// The checks a new engine must pass before it is used.
public enum EngineTrial {
  /// Loads an installed model on the new llama.cpp and runs the install probe: a reply, then a tool
  /// call. A model that was Ready must still be Ready.
  public static func llama(model: InstalledModel, store: ModelStore) -> EngineUpdater.Trial {
    { binaries in
      let runtime = try await LlamaRuntime.start(model: store.fileURL(model), alias: model.id, config: model.config, binaries: binaries)
      defer { runtime.stop() }
      let readiness = try await ModelVerifier().verify(baseURL: runtime.baseURL, apiKey: runtime.apiKey, model: model.id)
      if model.readiness == .ready && readiness != .ready {
        throw VerifyError.noReply("\(model.name) answered but no longer called a tool")
      }
    }
  }

  /// Starts the new harness against a running engine in an empty folder and waits until it answers.
  public static func opencode(runtime: LlamaRuntime) -> EngineUpdater.Trial {
    { binaries in
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agentgate-trial-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: folder) }
      let server = try await AgentServer.start(
        folder: folder, engineURL: runtime.baseURL, engineKey: runtime.apiKey, model: runtime.alias,
        context: ModelPlanner.preferredContext, binaries: binaries)
      server.stop()
    }
  }
}
