import Testing

@testable import AgentGateCore

@Test(arguments: [8, 16, 24, 32, 64, 128, 192] as [UInt64])
func tiersGrowFromFastToSmart(memory: UInt64) throws {
  let tiers = ModelPlanner.tiers(try Catalog.bundled(), for: mac(memory))
  let fast = try #require(tiers[.fast]), balanced = try #require(tiers[.balanced]), smart = try #require(tiers[.smart])
  #expect(fast.memoryBytes <= balanced.memoryBytes)
  #expect(balanced.memoryBytes <= smart.memoryBytes)
  // Tiers never quantize on the Mac or go below Q4_K_M when a Q4_K_M ready-made file fits.
  if memory >= 16 {
    for plan in [fast, balanced, smart] {
      #expect(plan.quant >= .q4_K_M)
      if case .quantizeLocally = plan.source { Issue.record("\(plan.modelId) would be quantized locally") }
    }
  }
}
