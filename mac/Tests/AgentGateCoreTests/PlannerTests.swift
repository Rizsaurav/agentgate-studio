import Foundation
import Testing

@testable import AgentGateCore

private let gib = MemoryBudget.gib

func mac(_ memory: UInt64, disk: UInt64 = 500, arch: HardwareProfile.Architecture = .appleSilicon) -> HardwareProfile {
  HardwareProfile(
    chip: "Apple M-test", architecture: arch, memoryBytes: memory * gib,
    gpuWorkingSetBytes: memory <= 36 ? memory * gib * 2 / 3 : memory * gib * 3 / 4, gpuCores: 10,
    performanceCores: 4, efficiencyCores: 4, freeDiskBytes: disk * gib, osVersion: "15.0.0")
}

@Test func bundledCatalogIsValid() throws {
  let catalog = try Catalog.bundled()
  #expect(catalog.models.count >= 10)
  #expect(catalog.model("qwen3-4b-2507")?.toolCalling == true)
}

@Test(arguments: [8, 16, 24, 32, 64, 96, 128, 192] as [UInt64])
func everyMemoryClassGetsThreeTiersThatFit(memory: UInt64) throws {
  let catalog = try Catalog.bundled()
  let profile = mac(memory)
  let tiers = ModelPlanner.tiers(catalog, for: profile)
  #expect(tiers.count == 3)
  for plan in tiers.values {
    #expect(plan.memoryBytes <= profile.modelBudgetBytes)
    #expect(plan.context >= 8192)
  }
  // Bigger Macs never get a smaller Smart model.
  if memory > 8, let smaller = ModelPlanner.tiers(catalog, for: mac(memory / 2))[.smart], let smart = tiers[.smart] {
    #expect(smart.memoryBytes >= smaller.memoryBytes)
  }
}

@Test func sameTierDiffersByMac() throws {
  let catalog = try Catalog.bundled()
  let small = ModelPlanner.tiers(catalog, for: mac(8))[.smart]?.modelId
  let large = ModelPlanner.tiers(catalog, for: mac(64))[.smart]?.modelId
  #expect(small != large)
}

@Test func choosesHighestQualityThatFits() throws {
  let model = try #require(try Catalog.bundled().model("qwen3-8b"))
  let big = try #require(ModelPlanner.plan(model, for: mac(64)).plan)
  #expect(big.quant == .q8_0)
  #expect(big.context == 32768)
  let small = try #require(ModelPlanner.plan(model, for: mac(16)).plan)
  #expect(small.quant < .q8_0)
  #expect(small.memoryBytes <= mac(16).modelBudgetBytes)
  #expect(small.reason.contains(small.quant.rawValue))
}

@Test func tooBigModelIsIncompatibleWithReason() throws {
  let model = try #require(try Catalog.bundled().model("qwen3-32b"))
  guard case .incompatible(let reason) = ModelPlanner.plan(model, for: mac(8)) else {
    Issue.record("a 32B model must not fit an 8 GB Mac"); return
  }
  #expect(reason.contains("memory"))
}

@Test func notEnoughDiskIsIncompatible() throws {
  let model = try #require(try Catalog.bundled().model("qwen3-8b"))
  guard case .incompatible(let reason) = ModelPlanner.plan(model, for: mac(64, disk: 3)) else {
    Issue.record("must not plan a download larger than free disk"); return
  }
  #expect(reason.contains("disk"))
}

@Test func readyMadeFilePreferredOverLocalQuantization() throws {
  // Qwen3 1.7B ships only at Q8_0: on 8 GB the ready-made file at 8K beats quantizing to Q6_K.
  let model = try #require(try Catalog.bundled().model("qwen3-1.7b"))
  let plan = try #require(ModelPlanner.plan(model, for: mac(8)).plan)
  #expect(plan.quant == .q8_0)
  guard case .ggufFile = plan.source else { Issue.record("expected the ready-made file"); return }
}

@Test func quantizesLocallyWhenNoReadyMadeFileFits() throws {
  var model = try #require(try Catalog.bundled().model("qwen3-1.7b"))
  model.gguf.files = []
  let plan = try #require(ModelPlanner.plan(model, for: mac(8)).plan)
  guard case .quantizeLocally(_, let quant) = plan.source else { Issue.record("expected local quantization"); return }
  #expect(quant == plan.quant)
  #expect(plan.diskBytes > plan.downloadBytes)
  #expect(plan.reason.contains("quantized on this Mac"))
}

@Test func mlxOnlyWhenPreferredAndOnAppleSilicon() throws {
  let model = try #require(try Catalog.bundled().model("qwen3-4b-2507"))
  #expect(ModelPlanner.plan(model, for: mac(24), prefer: .mlx).plan?.backend == .mlx)
  #expect(ModelPlanner.plan(model, for: mac(24)).plan?.backend == .llamaCpp)
  #expect(ModelPlanner.plan(model, for: mac(24, arch: .intel), prefer: .mlx).plan?.backend == .llamaCpp)
}

@Test(arguments: [
  ("version", #"{"version":2}"#),
  ("unknown tier model", #"{"tiers":{"fast":{"share":0.4,"candidates":["nope"]}}}"#),
  ("bad file", #"{"badFile":true}"#),
])
func malformedCatalogIsRejected(label: String, patch: String) throws {
  let url = try #require(Bundle.module.url(forResource: "catalog", withExtension: "json"))
  var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  let change = try #require(try JSONSerialization.jsonObject(with: Data(patch.utf8)) as? [String: Any])
  if change["badFile"] != nil {
    var models = try #require(json["models"] as? [[String: Any]])
    var gguf = try #require(models[0]["gguf"] as? [String: Any])
    var files = try #require(gguf["files"] as? [[String: Any]])
    files[0]["file"] = "../../etc/passwd.gguf"
    gguf["files"] = files; models[0]["gguf"] = gguf; json["models"] = models
  } else if let tiers = change["tiers"] as? [String: Any] {
    var current = try #require(json["tiers"] as? [String: Any])
    current.merge(tiers) { $1 }; json["tiers"] = current
  } else {
    json.merge(change) { $1 }
  }
  #expect(throws: CatalogError.self, "\(label)") {
    try Catalog.decode(JSONSerialization.data(withJSONObject: json))
  }
}
