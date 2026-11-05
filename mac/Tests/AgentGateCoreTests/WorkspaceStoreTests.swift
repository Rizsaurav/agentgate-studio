import Foundation
import Testing

@testable import AgentGateCore

@Test func workspaceRoundTripsAndIsPrivate() throws {
  let file = FileManager.default.temporaryDirectory.appendingPathComponent("agentgate-ws-\(UUID().uuidString)/workspace.json")
  let store = WorkspaceStore(file: file)
  #expect(try store.load() == WorkspaceStore.Snapshot())
  let project = Project(id: UUID(), name: "Demo", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
  var snapshot = WorkspaceStore.Snapshot(projects: [project])
  snapshot.sessions = [Session(
    id: UUID(), projectId: project.id, modelId: "qwen3-4b-2507", modelName: "Qwen3 4B",
    createdAt: project.createdAt, messages: [ChatMessage(role: .user, content: "hi")])]
  try store.save(snapshot)
  #expect(try store.load() == snapshot)
  let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
  #expect(mode == 0o600)
}

@Test func projectNamesAreValidated() throws {
  #expect(try WorkspaceStore.validName("  Demo ") == "Demo")
  #expect(throws: WorkspaceError.invalidName) { try WorkspaceStore.validName("   ") }
  #expect(throws: WorkspaceError.invalidName) { try WorkspaceStore.validName(String(repeating: "a", count: 81)) }
}
