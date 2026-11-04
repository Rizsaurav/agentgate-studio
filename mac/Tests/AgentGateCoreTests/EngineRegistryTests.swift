import Foundation
import Testing

@testable import AgentGateCore

@Test func reapNeverTouchesUnrelatedProcesses() throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agentgate-engines-\(UUID().uuidString)")
  let registry = EngineRegistry(folder: folder)
  let sleeper = Process()
  sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
  sleeper.arguments = ["30"]
  try sleeper.run()
  defer { sleeper.terminate() }
  try registry.record(sleeper.processIdentifier)
  // A recorded pid that now belongs to another program is forgotten, not killed.
  #expect(registry.reapOrphans(binaries: devRuntime).isEmpty)
  #expect(sleeper.isRunning)
  #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
}
