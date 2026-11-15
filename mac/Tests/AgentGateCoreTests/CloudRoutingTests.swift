import Foundation
import Testing

@testable import AgentGateCore

@Suite struct CloudRoutingTests {
  static let list = #"""
  {"data":[
    {"id":"cheap/small","name":"Cheap Small","context_length":16384,"pricing":{"prompt":"0.0000001","completion":"0.0000004"},"supported_parameters":["tools"]},
    {"id":"mid/model","name":"Mid","context_length":131072,"pricing":{"prompt":"0.000001","completion":"0.000003"},"supported_parameters":["tools","temperature"]},
    {"id":"chat/only","name":"Chat Only","context_length":8192,"pricing":{"prompt":"0.0000002","completion":"0.0000002"},"supported_parameters":["temperature"]},
    {"id":"free/model:free","name":"Free","context_length":32768,"pricing":{"prompt":"0","completion":"0"}},
    {"id":"broken","pricing":{"prompt":"abc","completion":"0.1"},"context_length":1000},
    {"id":"bad id; rm -rf","name":"x","context_length":4096,"pricing":{"prompt":"0.000001","completion":"0.000001"}}
  ]}
  """#

  func suggestion(contextK: Int, billions: Double) throws -> ModelSuggestion {
    let model = try #require(try Catalog.bundled().models.first)
    return ModelSuggestion(model: model, plan: nil, installed: true, score: 1, reasons: [],
                           context: contextK * 1024, parameters: billions * 1e9)
  }

  func needs(tools: Bool = true, long: Bool = false, _ priority: TaskNeeds.Priority = .balanced) -> TaskNeeds {
    TaskNeeds(tools: tools, longContext: long, priority: priority, summary: "task")
  }

  @Test func pricesAreReadPerMillionAndBadEntriesAreLeftOut() {
    let offers = CloudCatalog.parseOpenRouter(Data(Self.list.utf8))
    #expect(offers.map(\.id) == ["cheap/small", "mid/model", "chat/only"])
    let cheap = offers[0]
    #expect(abs(cheap.promptPerMillion - 0.1) < 1e-9 && abs(cheap.completionPerMillion - 0.4) < 1e-9)
    #expect(cheap.priceLabel == "$0.10 in · $0.40 out per million tokens")
    #expect(offers[1].toolCalling && !offers[2].toolCalling)
  }

  @Test func aLocalModelThatFitsKeepsTheTaskLocal() throws {
    let offers = CloudCatalog.parseOpenRouter(Data(Self.list.utf8))
    let local = [try suggestion(contextK: 32, billions: 8)]
    #expect(TaskRouter.advise(needs: needs(), local: local, connected: offers) == .local)
    #expect(TaskRouter.advise(needs: needs(long: true, .quality), local: local, connected: offers) == .local)
  }

  @Test func whenNothingLocalIsEnoughConnectedCloudModelsAreOfferedWithPrices() throws {
    let offers = CloudCatalog.parseOpenRouter(Data(Self.list.utf8))
    guard case .cloudSuggested(let reason, let picks) = TaskRouter.advise(
      needs: needs(long: true), local: [try suggestion(contextK: 16, billions: 8)], connected: offers) else {
      Issue.record("expected cloud"); return
    }
    #expect(reason.contains("16K"))
    // Long inputs and tools: only the 128K tool model qualifies.
    #expect(picks.map(\.id) == ["mid/model"])
    guard case .cloudSuggested(_, let any) = TaskRouter.advise(needs: needs(), local: [], connected: offers) else {
      Issue.record("expected cloud"); return
    }
    #expect(any.map(\.id) == ["cheap/small", "mid/model"])
    #expect(any.allSatisfy { $0.priceLabel.contains("per million tokens") })
  }

  @Test func bestQualityOnASmallMacAsksForMoreThanItHas() throws {
    let local = [try suggestion(contextK: 32, billions: 3)]
    guard case .cloudSuggested(let reason, _) = TaskRouter.advise(needs: needs(.quality), local: local, connected: []) else {
      Issue.record("expected cloud"); return
    }
    #expect(reason.contains("3B"))
  }

  @Test func withoutAConnectedKeyNothingIsOfferedButTheReasonIsShown() {
    guard case .cloudSuggested(let reason, let picks) = TaskRouter.advise(needs: needs(), local: [], connected: []) else {
      Issue.record("expected cloud"); return
    }
    #expect(picks.isEmpty)
    #expect(reason.contains("calls tools"))
  }

  @Test func theAdvisorFillsContextAndSize() throws {
    let catalog = try Catalog.bundled()
    let mac = HardwareProfile(chip: "M3", architecture: .appleSilicon, memoryBytes: 32 * MemoryBudget.gib,
                              gpuWorkingSetBytes: 24 * MemoryBudget.gib, gpuCores: 10, performanceCores: 4,
                              efficiencyCores: 4, freeDiskBytes: 500 * MemoryBudget.gib, osVersion: "15")
    let picks = ModelAdvisor.suggest(catalog, for: mac, installed: [], needs: needs())
    #expect(!picks.isEmpty)
    #expect(picks.allSatisfy { $0.context >= 8192 && $0.parameters > 1e8 })
  }
}
