import AgentGateCore
import Foundation
import Observation

/// One row in the model selector.
struct ModelOption: Identifiable, Equatable {
  enum State: Equatable {
    case ready
    case chatOnly
    case notInstalled(download: UInt64)
    case incompatible(String)
  }

  var model: CatalogModel
  var plan: ModelPlan?
  var state: State
  var id: String { model.id }
}

@MainActor @Observable
final class AppModel {
  private(set) var profile: HardwareProfile?
  private(set) var catalog: Catalog?
  private(set) var tiers: [Tier: ModelPlan] = [:]
  private(set) var installed: [InstalledModel] = []
  private(set) var active: InstalledModel?
  private(set) var update: InstallUpdate?
  private(set) var failure: InstallFailure?
  private(set) var installing: CatalogModel?
  private(set) var loadError: String?
  var messages: [ChatMessage] = []
  private(set) var thinking = false
  private(set) var generating = false

  private let pipeline = InstallPipeline()
  private let store = ModelStore()
  private var runtime: LlamaRuntime?
  private var installTask: Task<Void, Never>?

  func start() {
    do {
      catalog = try Catalog.bundled()
      let profile = try HardwareProbe.current(modelsDirectory: store.root)
      self.profile = profile
      tiers = ModelPlanner.tiers(catalog!, for: profile)
      installed = try store.list()
    } catch {
      loadError = String(describing: error)
    }
  }

  func option(_ model: CatalogModel) -> ModelOption {
    if let done = installed.first(where: { $0.id == model.id }) {
      return ModelOption(model: model, plan: nil, state: done.readiness == .ready ? .ready : .chatOnly)
    }
    guard let profile else { return ModelOption(model: model, plan: nil, state: .incompatible("Hardware unknown")) }
    switch ModelPlanner.plan(model, for: profile, limits: InstallPipeline.supported) {
    case .compatible(let plan): return ModelOption(model: model, plan: plan, state: .notInstalled(download: plan.downloadBytes))
    case .incompatible(let reason): return ModelOption(model: model, plan: nil, state: .incompatible(reason))
    }
  }

  var allOptions: [ModelOption] { catalog?.models.map(option) ?? [] }

  /// Selecting installs if needed, then loads the model for chat.
  func select(_ model: CatalogModel) {
    guard installing == nil else { return }
    failure = nil
    installing = model
    stopRuntime()
    installTask = Task {
      defer { installing = nil }
      do {
        let report: @Sendable (InstallUpdate) -> Void = { update in Task { @MainActor in self.update = update } }
        if let done = installed.first(where: { $0.id == model.id }) {
          runtime = try await pipeline.load(done, update: report)
          activate(done)
        } else {
          let (done, runtime) = try await pipeline.install(model, update: report)
          self.runtime = runtime
          installed = try store.list()
          activate(done)
        }
      } catch let failure as InstallFailure {
        self.failure = failure
        update = nil
      } catch {
        self.failure = InstallFailure(step: update?.step ?? .load, message: String(describing: error), cause: error, logTail: nil)
        update = nil
      }
    }
  }

  func cancelInstall() {
    installTask?.cancel()
  }

  func dismissFailure() { failure = nil }

  func dismissUpdate() { update = nil }

  private func activate(_ model: InstalledModel) {
    active = model
    messages = []
  }

  func remove(_ model: InstalledModel) {
    if active?.id == model.id {
      stopRuntime()
      active = nil
    }
    do {
      try store.remove(model.id)
      installed = try store.list()
    } catch {
      loadError = String(describing: error)
    }
  }

  func send(_ text: String) {
    guard let runtime, let active, !generating else { return }
    messages.append(ChatMessage(role: .user, content: text))
    messages.append(ChatMessage(role: .assistant, content: ""))
    let index = messages.count - 1
    let history = Array(messages.dropLast())
    generating = true
    Task {
      defer { generating = false; thinking = false }
      do {
        let client = ChatClient(baseURL: runtime.baseURL, apiKey: runtime.apiKey, model: active.id)
        for try await chunk in client.stream(history) {
          switch chunk {
          case .thinking: thinking = true
          case .text(let text):
            thinking = false
            messages[index].content += text
          }
        }
      } catch {
        messages[index].content += messages[index].content.isEmpty ? "" : "\n\n"
        messages[index].content += "Error: \(error)"
      }
    }
  }

  func stopRuntime() {
    runtime?.stop()
    runtime = nil
  }
}
