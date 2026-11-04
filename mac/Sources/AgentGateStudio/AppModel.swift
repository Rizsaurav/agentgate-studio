import AgentGateCore
import Foundation
import Observation

/// One row in the model lists.
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

enum Route: Hashable {
  case workspace
  case project(UUID)
  case session(UUID)
  case security
  case models
}

@MainActor @Observable
final class AppModel {
  var route: Route = .workspace
  var paletteOpen = false
  private(set) var profile: HardwareProfile?
  private(set) var catalog: Catalog?
  private(set) var tiers: [Tier: ModelPlan] = [:]
  private(set) var installed: [InstalledModel] = []
  private(set) var active: InstalledModel?
  private(set) var update: InstallUpdate?
  private(set) var failure: InstallFailure?
  private(set) var installing: CatalogModel?
  /// A repair waiting for the user's yes or no.
  private(set) var pendingRepair: (operation: RepairOperation, report: FailureReport)?
  private var repairAnswer: CheckedContinuation<Bool, Never>?
  /// Whether the repair agent (OpenRouter) is connected. The key itself never leaves the Keychain.
  private(set) var agentOn = OpenRouterAssistant.isConnected
  var setupSkipped = UserDefaults.standard.bool(forKey: "setupSkipped") {
    didSet { UserDefaults.standard.set(setupSkipped, forKey: "setupSkipped") }
  }
  var errorMessage: String?
  private(set) var workspace = WorkspaceStore.Snapshot()
  private(set) var thinking = false
  private(set) var generating = false

  private let pipeline = InstallPipeline()
  private let store = ModelStore()
  private let workspaceStore = WorkspaceStore()
  private var runtime: LlamaRuntime?
  private var installTask: Task<Bool, Never>?

  func start() {
    do {
      let catalog = try Catalog.bundled()
      self.catalog = catalog
      let profile = try HardwareProbe.current(modelsDirectory: store.root)
      self.profile = profile
      tiers = ModelPlanner.tiers(catalog, for: profile)
      installed = try store.list()
      workspace = try workspaceStore.load()
    } catch {
      errorMessage = String(describing: error)
    }
  }

  // MARK: Workspace

  var projects: [Project] { workspace.projects.sorted { $0.createdAt > $1.createdAt } }

  func project(_ id: UUID) -> Project? { workspace.projects.first { $0.id == id } }

  func session(_ id: UUID) -> Session? { workspace.sessions.first { $0.id == id } }

  func sessions(in project: UUID) -> [Session] {
    workspace.sessions.filter { $0.projectId == project }.sorted { $0.createdAt > $1.createdAt }
  }

  func createProject(named name: String) -> Bool {
    do {
      let project = Project(id: UUID(), name: try WorkspaceStore.validName(name), createdAt: Date())
      workspace.projects.append(project)
      try persist()
      route = .project(project.id)
      return true
    } catch {
      errorMessage = String(describing: error)
      return false
    }
  }

  func startSession(in project: UUID, with model: InstalledModel) {
    let session = Session(
      id: UUID(), projectId: project, modelId: model.id, modelName: model.name, createdAt: Date(), messages: [])
    workspace.sessions.append(session)
    do { try persist() } catch { errorMessage = String(describing: error) }
    route = .session(session.id)
    if active?.id != model.id, let entry = catalog?.model(model.id) { select(entry) }
  }

  private func persist() throws { try workspaceStore.save(workspace) }

  // MARK: Models

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

  /// Installs the model if needed, then loads it. One install or load at a time.
  @discardableResult
  func select(_ model: CatalogModel) -> Task<Bool, Never>? {
    if let installTask, installing != nil { return installTask }
    failure = nil
    installing = model
    stopRuntime()
    let task = Task { () -> Bool in
      defer { installing = nil }
      do {
        let report: @Sendable (InstallUpdate) -> Void = { update in Task { @MainActor in self.update = update } }
        if let done = installed.first(where: { $0.id == model.id }) {
          runtime = try await pipeline.load(done, update: report)
          active = done
        } else {
          let runner = RepairRunner(assistant: agentOn ? OpenRouterAssistant() : nil) { operation, failure in
            await self.askToRepair(operation, failure)
          }
          let (done, runtime) = try await runner.install(model, update: report)
          self.runtime = runtime
          installed = try store.list()
          active = done
        }
        return true
      } catch let failure as InstallFailure {
        self.failure = failure
        update = nil
      } catch RepairError.unrepaired(let failure, let why) {
        var shown = failure
        shown.message += " \(why)"
        self.failure = shown
        update = nil
      } catch {
        failure = InstallFailure(step: update?.step ?? .load, message: String(describing: error), cause: error, logTail: nil)
        update = nil
      }
      return false
    }
    installTask = task
    return task
  }

  /// Saves the key in the Keychain. Returns false (with a message) if it could not be saved.
  func connectAgent(key: String) -> Bool {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    do {
      try OpenRouterAssistant.keychain.save(trimmed)
      agentOn = true
      return true
    } catch {
      errorMessage = String(describing: error)
      return false
    }
  }

  func disconnectAgent() {
    do {
      try OpenRouterAssistant.keychain.delete()
      agentOn = false
    } catch {
      errorMessage = String(describing: error)
    }
  }

  func cancelInstall() {
    answerRepair(false)
    installTask?.cancel()
  }

  private func askToRepair(_ operation: RepairOperation, _ report: FailureReport) async -> Bool {
    await withCheckedContinuation { continuation in
      pendingRepair = (operation, report)
      repairAnswer = continuation
    }
  }

  func answerRepair(_ approved: Bool) {
    pendingRepair = nil
    repairAnswer?.resume(returning: approved)
    repairAnswer = nil
  }

  func dismissFailure() { failure = nil }

  func dismissUpdate() { update = nil }

  func remove(_ model: InstalledModel) {
    if active?.id == model.id {
      stopRuntime()
      active = nil
    }
    do {
      try store.remove(model.id)
      installed = try store.list()
    } catch {
      errorMessage = String(describing: error)
    }
  }

  func stopRuntime() {
    runtime?.stop()
    runtime = nil
  }

  // MARK: Chat

  /// Sends a task in a session, loading the session's model first when another one is loaded.
  func send(_ text: String, in sessionId: UUID) {
    guard !generating, let index = workspace.sessions.firstIndex(where: { $0.id == sessionId }) else { return }
    let session = workspace.sessions[index]
    workspace.sessions[index].messages.append(ChatMessage(role: .user, content: text))
    workspace.sessions[index].messages.append(ChatMessage(role: .assistant, content: ""))
    let history = Array(workspace.sessions[index].messages.dropLast())
    generating = true
    Task {
      defer {
        generating = false
        thinking = false
        try? persist()
      }
      // Load the session's model, or reload it if its engine has died since the last message.
      if active?.id != session.modelId || runtime?.isRunning != true {
        guard let entry = catalog?.model(session.modelId), let task = select(entry), await task.value else {
          append("The model for this session could not be loaded.", to: sessionId)
          return
        }
      }
      guard let runtime else { return }
      do {
        let client = ChatClient(baseURL: runtime.baseURL, apiKey: runtime.apiKey, model: session.modelId)
        for try await chunk in client.stream(history) {
          switch chunk {
          case .thinking: thinking = true
          case .text(let text):
            thinking = false
            append(text, to: sessionId)
          }
        }
      } catch {
        append("\n\nError: \(error)", to: sessionId)
      }
    }
  }

  private func append(_ text: String, to sessionId: UUID) {
    guard let index = workspace.sessions.firstIndex(where: { $0.id == sessionId }),
          let last = workspace.sessions[index].messages.indices.last else { return }
    workspace.sessions[index].messages[last].content += text
  }
}
