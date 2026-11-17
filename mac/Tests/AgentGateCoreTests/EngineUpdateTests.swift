import Foundation
import Testing

@testable import AgentGateCore

@Suite struct EngineUpdateTests {
  // MARK: Pins

  @Test func bundledPinsAreValidAndInOnePlace() throws {
    let manifest = try EngineManifest.bundled()
    #expect(manifest.engines[.llama]?.tag.hasPrefix("b") == true)
    // The fetch scripts read this same file; no other copy of a pin may exist.
    let scripts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("scripts")
    for name in ["fetch_runtime.sh", "fetch_opencode.sh"] {
      let text = try String(contentsOf: scripts.appendingPathComponent(name), encoding: .utf8)
      #expect(text.contains("engines.json"))
      for pin in manifest.engines.values { #expect(!text.contains(pin.sha256), "\(name) repeats a checksum") }
    }
  }

  @Test(arguments: [
    "http://github.com/o/r/releases/download/b1/x.tar.gz",
    "https://example.com/o/r/releases/download/b1/x.tar.gz",
    "https://github.com/o/r/releases/download/b2/x.tar.gz",
    "https://github.com/o/r/releases/download/b1/x.dmg",
  ])
  func manifestRejectsUntrustedPins(url: String) {
    let json = """
      {"version":1,"engines":{"llama":{"tag":"b1","url":"\(url)","sha256":"\(String(repeating: "a", count: 64))"},
      "opencode":{"tag":"v1","url":"https://github.com/o/r/releases/download/v1/o.zip","sha256":"\(String(repeating: "b", count: 64))"}}}
      """
    #expect(throws: EngineUpdateError.self) { try EngineManifest.decode(Data(json.utf8)) }
  }

  @Test func onlyDifferentTagsAreOffered() throws {
    let work = try Work()
    let bundled = work.root.appendingPathComponent("bundled")
    try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
    try "b1".write(to: bundled.appendingPathComponent(".tag"), atomically: true, encoding: .utf8)
    let manifest = EngineManifest(version: 1, engines: [.llama: work.pin("b1"), .opencode: work.pin("v2")])
    let offered = EngineUpdater(store: work.store).available(manifest, bundled: [.llama: bundled, .opencode: nil])
    #expect(Array(offered.keys) == [.opencode])
  }

  // MARK: Install, trial, roll back

  @Test func aPassingUpdateBecomesActiveAndKeepsThePreviousOne() async throws {
    let work = try Work()
    let updater = work.updater(archives: ["b2": try work.archive(.llama), "b3": try work.archive(.llama), "b4": try work.archive(.llama)])
    try await updater.install(.llama, work.pin("b2"), trial: { _ in })
    #expect(work.store.activeDirectory(.llama)?.lastPathComponent == "b2")
    #expect(try String(contentsOf: work.store.folder(.llama, "b2").appendingPathComponent(".tag"), encoding: .utf8) == "b2")
    try await updater.install(.llama, work.pin("b3"), trial: { _ in })
    #expect(try work.store.state()[.llama] == .init(active: "b3", previous: "b2"))
    try await updater.install(.llama, work.pin("b4"), trial: { _ in })
    // Only one way back is kept.
    #expect(try work.store.state()[.llama] == .init(active: "b4", previous: "b3"))
    #expect(!FileManager.default.fileExists(atPath: work.store.folder(.llama, "b2").path))
  }

  @Test func aFailingTrialRemovesTheNewVersionAndKeepsTheOldOne() async throws {
    let work = try Work()
    let updater = work.updater(archives: ["b2": try work.archive(.llama), "b3": try work.archive(.llama)])
    try await updater.install(.llama, work.pin("b2"), trial: { _ in })
    struct Broken: Error {}
    await #expect(throws: EngineUpdateError.self) {
      try await updater.install(.llama, work.pin("b3"), trial: { _ in throw Broken() })
    }
    #expect(work.store.activeDirectory(.llama)?.lastPathComponent == "b2")
    #expect(!FileManager.default.fileExists(atPath: work.store.folder(.llama, "b3").path))
    #expect(work.modelsAndProjectsUntouched())
  }

  @Test func aCrashingEngineBuildIsRejectedByTheRealTrial() async throws {
    let work = try Work()
    // A llama-server that exits at once, like a build for the wrong OS or with a missing library.
    let updater = work.updater(archives: ["b9": try work.archive(.llama, script: "echo 'dyld: Library not loaded' >&2; exit 134")])
    let modelFile = work.root.appendingPathComponent("models/tiny/tiny.gguf")
    try FileManager.default.createDirectory(at: modelFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("GGUF".utf8).write(to: modelFile)
    let model = InstalledModel(
      id: "tiny", name: "Tiny", quant: .q8_0, file: "tiny.gguf", sha256: String(repeating: "0", count: 64), bytes: 4,
      backend: .llamaCpp, config: RuntimeConfig(context: 2048, gpuLayers: 0, kvCacheType: "f16", flashAttention: false, threads: 1),
      readiness: .ready, reason: "", verifiedAt: Date())
    await #expect(throws: EngineUpdateError.self) {
      try await updater.install(.llama, work.pin("b9"), trial: EngineTrial.llama(model: model, store: ModelStore(root: work.root.appendingPathComponent("models"))))
    }
    #expect(work.store.activeDirectory(.llama) == nil)
    #expect(try work.store.state()[.llama] == nil)
    #expect(FileManager.default.fileExists(atPath: modelFile.path))
  }

  @Test func aWrongChecksumOrAMissingProgramChangesNothing() async throws {
    let work = try Work()
    var pin = work.pin("b2")
    let updater = work.updater(archives: ["b2": try work.archive(.llama)])
    pin.sha256 = String(repeating: "f", count: 64)
    await #expect(throws: EngineUpdateError.checksumMismatch(.llama)) { try await updater.install(.llama, pin, trial: { _ in }) }
    let empty = work.updater(archives: ["b3": try work.archive(.llama, binary: "something-else")])
    await #expect(throws: EngineUpdateError.binaryMissing(.llama)) { try await empty.install(.llama, work.pin("b3"), trial: { _ in }) }
    #expect(try work.store.state().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: work.store.folder(.llama, "b3").path))
  }

  @Test func zipReleasesInstallToo() async throws {
    let work = try Work()
    let updater = work.updater(archives: ["v2": try work.archive(.opencode, zip: true)])
    try await updater.install(.opencode, work.pin("v2", zip: true), trial: { _ in })
    #expect(work.store.activeDirectory(.opencode)?.lastPathComponent == "v2")
  }

  @Test func rollingBackGoesToThePreviousThenToTheBundledEngine() async throws {
    let work = try Work()
    let updater = work.updater(archives: ["b2": try work.archive(.llama), "b3": try work.archive(.llama)])
    #expect(throws: EngineUpdateError.nothingToRollBack(.llama)) { try work.store.rollBack(.llama) }
    try await updater.install(.llama, work.pin("b2"), trial: { _ in })
    try await updater.install(.llama, work.pin("b3"), trial: { _ in })
    try work.store.rollBack(.llama)
    #expect(work.store.activeDirectory(.llama)?.lastPathComponent == "b2")
    try work.store.rollBack(.llama)
    #expect(work.store.activeDirectory(.llama) == nil)
    #expect(work.modelsAndProjectsUntouched())
  }

  @Test func anActiveVersionWithoutItsProgramFallsBackToTheBundledOne() async throws {
    let work = try Work()
    try await work.updater(archives: ["b2": try work.archive(.llama)]).install(.llama, work.pin("b2"), trial: { _ in })
    try FileManager.default.removeItem(at: work.store.folder(.llama, "b2").appendingPathComponent("llama-server"))
    #expect(work.store.activeDirectory(.llama) == nil)
  }
}

/// A temporary folder with an engine store, release archives, and a models and projects folder that must survive.
private final class Work: @unchecked Sendable {
  let root: URL
  let store: EngineStore
  private var archives: [String: URL] = [:]

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("engines-\(UUID().uuidString)", isDirectory: true)
    store = EngineStore(root: root.appendingPathComponent("runtimes"))
    for keep in ["models/qwen/manifest.json", "projects/app/README.md"] {
      let url = root.appendingPathComponent(keep)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("keep".utf8).write(to: url)
    }
  }

  deinit { try? FileManager.default.removeItem(at: root) }

  func modelsAndProjectsUntouched() -> Bool {
    ["models/qwen/manifest.json", "projects/app/README.md"].allSatisfy {
      (try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)) == "keep"
    }
  }

  /// A release archive holding `build/bin/<binary>` and a library beside it, like a llama.cpp release.
  func archive(_ kind: EngineKind, binary: String? = nil, script: String = "exit 0", zip: Bool = false) throws -> URL {
    let source = root.appendingPathComponent("src-\(UUID().uuidString)")
    let bin = source.appendingPathComponent("build/bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let program = bin.appendingPathComponent(binary ?? kind.binary)
    try "#!/bin/sh\n\(script)\n".write(to: program, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
    try Data("lib".utf8).write(to: bin.appendingPathComponent("libggml.dylib"))
    let out = root.appendingPathComponent("\(UUID().uuidString).\(zip ? "zip" : "tar.gz")")
    let process = Process()
    if zip {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
      process.arguments = ["-c", "-k", source.path, out.path]
    } else {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
      process.arguments = ["-czf", out.path, "-C", source.path, "build"]
    }
    try process.run()
    process.waitUntilExit()
    return out
  }

  func pin(_ tag: String, zip: Bool = false) -> EnginePin {
    let file = archives[tag]
    let sha = (file.flatMap { try? EngineUpdater.sha256(of: $0) }) ?? String(repeating: "a", count: 64)
    return EnginePin(tag: tag, url: URL(string: "https://github.com/o/r/releases/download/\(tag)/x.\(zip ? "zip" : "tar.gz")")!, sha256: sha)
  }

  /// An updater whose downloads come from the local archives, by tag.
  func updater(archives: [String: URL]) -> EngineUpdater {
    self.archives.merge(archives) { $1 }
    let byTag = self.archives
    let temp = root
    return EngineUpdater(store: store) { url in
      let tag = url.deletingLastPathComponent().lastPathComponent
      guard let source = byTag[tag] else { throw URLError(.fileDoesNotExist) }
      // The updater deletes what it downloaded, so hand it a copy.
      let copy = temp.appendingPathComponent("download-\(UUID().uuidString)")
      try FileManager.default.copyItem(at: source, to: copy)
      return copy
    }
  }
}

/// Installs the real pinned llama.cpp release into a temporary store and runs the real trial with a model.
/// Set AGENTGATE_LIVE_ENGINE=1 and AGENTGATE_MEASURE_GGUF to a Qwen3 0.6B Q8_0 file; skipped otherwise.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AGENTGATE_LIVE_ENGINE"] == "1"))
struct EngineUpdateLiveTests {
  @Test func installsAndTrialsTheRealPinnedEngine() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("engine-live-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let gguf = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AGENTGATE_MEASURE_GGUF"]!)
    let models = ModelStore(root: root.appendingPathComponent("models"))
    try FileManager.default.createDirectory(at: models.folder("qwen3-0.6b"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: models.folder("qwen3-0.6b").appendingPathComponent(gguf.lastPathComponent), withDestinationURL: gguf)
    let model = InstalledModel(
      id: "qwen3-0.6b", name: "Qwen3 0.6B", quant: .q8_0, file: gguf.lastPathComponent, sha256: "", bytes: 0, backend: .llamaCpp,
      config: RuntimeConfig(context: 8192, gpuLayers: 999, kvCacheType: "q8_0", flashAttention: true, threads: 4),
      readiness: .ready, reason: "", verifiedAt: Date())
    let store = EngineStore(root: root.appendingPathComponent("runtimes"))
    let pin = try #require(try EngineManifest.bundled().engines[.llama])
    try await EngineUpdater(store: store).install(.llama, pin, trial: EngineTrial.llama(model: model, store: models))
    #expect(store.activeDirectory(.llama)?.lastPathComponent == pin.tag)

    // The harness: the real pinned OpenCode must start against that engine before it is used.
    let runtime = try await LlamaRuntime.start(
      model: models.fileURL(model), alias: model.id, config: model.config, binaries: store.activeDirectory(.llama))
    defer { runtime.stop() }
    let harness = try #require(try EngineManifest.bundled().engines[.opencode])
    try await EngineUpdater(store: store).install(.opencode, harness, trial: EngineTrial.opencode(runtime: runtime))
    #expect(store.activeDirectory(.opencode)?.lastPathComponent == harness.tag)
  }
}
