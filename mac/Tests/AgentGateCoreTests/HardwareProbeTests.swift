import Foundation
import Testing

@testable import AgentGateCore

@Test func readsThisMac() throws {
  let missing = FileManager.default.temporaryDirectory.appendingPathComponent("agentgate-missing/a/b")
  let profile = try HardwareProbe.current(modelsDirectory: missing)
  #expect(profile.memoryBytes > 0)
  #expect(profile.gpuWorkingSetBytes > 0)
  #expect(profile.performanceCores > 0)
  #expect(profile.freeDiskBytes > 0)
  #expect(!profile.chip.isEmpty)
}

@Test func unknownSysctlThrows() {
  #expect(throws: HardwareProbeError.sysctl("hw.agentgate-nope")) {
    try HardwareProbe.int("hw.agentgate-nope")
  }
}
