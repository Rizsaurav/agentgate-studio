import Testing

@testable import AgentGateCore

private let gib = MemoryBudget.gib

/// GPU working-set limits macOS reports, roughly two thirds of memory up to 36 GB, three quarters above.
private func workingSet(_ memory: UInt64) -> UInt64 {
  memory <= 36 * gib ? memory * 2 / 3 : memory * 3 / 4
}

@Test(arguments: [
  (8, 3.0), (16, 9.17), (24, 14.5), (32, 19.83), (64, 46.5), (96, 70.5), (128, 94.5), (192, 142.5),
] as [(UInt64, Double)])
func budgetPerMemoryClass(memory: UInt64, expected: Double) {
  let bytes = MemoryBudget.modelBytes(memory: memory * gib, gpuWorkingSet: workingSet(memory * gib))
  #expect(abs(Double(bytes) / Double(gib) - expected) < 0.01)
}

@Test func budgetNeverUnderflows() {
  #expect(MemoryBudget.modelBytes(memory: 4 * gib, gpuWorkingSet: 2 * gib) == 0)
  #expect(MemoryBudget.modelBytes(memory: 0, gpuWorkingSet: 0) == 0)
}

@Test func summaryIsOneReadableLine() {
  let profile = HardwareProfile(
    chip: "Apple M2", architecture: .appleSilicon, memoryBytes: 16 * gib,
    gpuWorkingSetBytes: 11 * gib, gpuCores: 10, performanceCores: 4, efficiencyCores: 4,
    freeDiskBytes: 210 * gib + 512, osVersion: "15.0.0")
  #expect(profile.summary == "Apple M2 · 16 GB · 210 GB free")
  #expect(profile.notice == nil)
}
