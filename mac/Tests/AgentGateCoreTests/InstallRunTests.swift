import Foundation
import Testing

@testable import AgentGateCore

@Suite struct InstallRunTests {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("runs-\(UUID().uuidString)")

  @Test func aRunSurvivesARestartAndFinishedOnesAreCleanedUp() throws {
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = InstallRunStore(folder: folder)
    var run = InstallRun(modelId: "qwen3-8b", modelName: "Qwen3 8B")
    run.record(InstallUpdate(step: .hardware, message: "Apple M5"))
    run.record(InstallUpdate(step: .download, message: "Downloading 0.1 GB of 8 GB", completedBytes: 1, totalBytes: 8))
    run.record(InstallUpdate(step: .download, message: "Downloading 2.0 GB of 8 GB", completedBytes: 2, totalBytes: 8))
    try store.save(run)
    var other = InstallRun(modelId: "done-model", modelName: "Done")
    other.record(InstallUpdate(step: .ready, message: "Ready"))
    try store.save(other)

    let loaded = store.unfinished(installed: ["done-model"])
    #expect(loaded.map(\.modelId) == ["qwen3-8b"])
    #expect(loaded[0].step == .download)
    // Progress replaced its own line instead of piling up.
    #expect(loaded[0].log[.download] == ["Downloading 2.0 GB of 8 GB"])
    #expect(store.unfinished(installed: []).map(\.modelId) == ["qwen3-8b"])
    let mode = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("qwen3-8b.json").path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
  }

  @Test func removeForgetsARun() throws {
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = InstallRunStore(folder: folder)
    try store.save(InstallRun(modelId: "m", modelName: "M"))
    store.remove("m")
    #expect(store.unfinished(installed: []).isEmpty)
  }
}
