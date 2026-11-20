import Foundation
import Testing

@testable import AgentGateCore

@Suite struct StorageTests {
  private func folder() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-\(UUID().uuidString)", isDirectory: true)
    for (path, bytes) in ["qwen/model.gguf": 4096, "qwen/manifest.json": 10, "big/model.gguf.part": 8192, "other/x.gguf.part": 100] {
      let url = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(count: bytes).write(to: url)
    }
    return root
  }

  @Test func onlyPartialDownloadsAreDeleted() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(Storage.partialDownloads(in: root).map(\.lastPathComponent) == ["model.gguf.part", "x.gguf.part"])
    let freed = try Storage.removePartialDownloads(in: root)
    #expect(freed >= 8192)
    #expect(Storage.partialDownloads(in: root).isEmpty)
    // Installed models and their manifests stay.
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("qwen/model.gguf").path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("qwen/manifest.json").path))
    #expect(try Storage.removePartialDownloads(in: root) == 0)
  }

  @Test func sizeCountsEveryFile() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(Storage.size(of: root) >= 4096 + 10 + 8192 + 100)
    #expect(Storage.size(of: root.appendingPathComponent("missing")) == 0)
  }

  @Test func clearingTheLogsRemovesTheRecordsOnly() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let security = SecurityLog(file: root.appendingPathComponent("security-log.json"))
    let audit = AuditLog(file: root.appendingPathComponent("repair-audit.json"))
    try security.append(SecurityEntry(date: Date(), project: "p", tool: "bash", detail: "rm -rf /", outcome: .blocked, rule: "destructive"))
    try audit.append(AuditEntry(date: Date(), modelId: "m", operation: "retry", reason: "r", outcome: .done))
    #expect(security.entries().count == 1 && audit.entries().count == 1)
    try security.clear()
    try audit.clear()
    #expect(security.entries().isEmpty && audit.entries().isEmpty)
    // Clearing an empty log is fine, and the rules are unaffected.
    try security.clear()
    if case .block = ToolPolicy.evaluate(tool: "bash", detail: "rm -rf ~", folder: root) {} else { Issue.record("the rules changed") }
  }
}
