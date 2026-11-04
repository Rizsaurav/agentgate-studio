import Foundation
import Testing

@testable import AgentGateCore

@Suite struct ModelAdvisorTests {
  let catalog = try! Catalog.bundled()

  @Test(arguments: [8, 16, 64] as [UInt64])
  func toolWorkNeverGetsAChatOnlyModel(memory: UInt64) {
    let needs = TaskNeeds(tools: true, longContext: false, priority: .balanced, summary: "fix my code")
    let picks = ModelAdvisor.suggest(catalog, for: mac(memory), installed: [], needs: needs)
    #expect(!picks.isEmpty)
    #expect(picks.allSatisfy { $0.model.toolCalling })
    #expect(picks.allSatisfy { ($0.plan?.memoryBytes ?? 0) <= mac(memory).modelBudgetBytes })
  }

  @Test func speedPrefersSmallerAndQualityPrefersBigger() {
    let fast = ModelAdvisor.suggest(catalog, for: mac(64), installed: [], needs: .init(tools: false, longContext: false, priority: .speed, summary: ""))
    let best = ModelAdvisor.suggest(catalog, for: mac(64), installed: [], needs: .init(tools: false, longContext: false, priority: .quality, summary: ""))
    let size = { (s: ModelSuggestion) in s.plan?.downloadBytes ?? 0 }
    #expect(size(fast[0]) < size(best[0]))
  }

  @Test func theBestMatchLeavesHeadroomWhenItCan() {
    let needs = TaskNeeds(tools: true, longContext: false, priority: .quality, summary: "")
    let pick = ModelAdvisor.suggest(catalog, for: mac(24), installed: [], needs: needs)[0]
    #expect(Double(pick.plan?.memoryBytes ?? 0) <= Double(mac(24).modelBudgetBytes) * 0.9)
  }

  @Test func sameInputsGiveTheSameAnswer() {
    let needs = TaskNeeds.fromKeywords("summarise long PDFs")
    let a = ModelAdvisor.suggest(catalog, for: mac(24), installed: [], needs: needs).map(\.id)
    let b = ModelAdvisor.suggest(catalog, for: mac(24), installed: [], needs: needs).map(\.id)
    #expect(a == b && a.count == 3)
  }

  @Test func keywordRulesReadCommonTasks() {
    #expect(TaskNeeds.fromKeywords("Refactor my Swift project and run the tests").tools)
    #expect(TaskNeeds.fromKeywords("Summarise this long PDF").longContext)
    #expect(TaskNeeds.fromKeywords("quick answers on battery").priority == .speed)
    #expect(!TaskNeeds.fromKeywords("chat about history").tools)
  }

  @Test func agentAnswersAreValidated() throws {
    let ok = try TaskNeeds.parse(#"{"tools":true,"longContext":false,"priority":"speed","summary":"code fixes"}"#)
    #expect(ok.tools && ok.priority == .speed)
    #expect(throws: (any Error).self) { try TaskNeeds.parse(#"{"tools":"yes","priority":"speed"}"#) }
    #expect(throws: (any Error).self) { try TaskNeeds.parse(#"{"tools":true,"longContext":false,"priority":"max","summary":""}"#) }
  }
}
