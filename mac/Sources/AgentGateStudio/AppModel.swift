import AgentGateCore
import AppKit
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
  case profile
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
  /// What each install step reported, for the dialog behind each dot in the status bar.
  /// The current or last install's record; the step dots read from it.
  private(set) var run: InstallRun?
  /// Installs that stopped before finishing (quit, crash, failure), offered for Resume or Discard.
  private(set) var resumable: [InstallRun] = []
  private let runStore = InstallRunStore()
  private var lastRunSave = Date.distantPast
  var stepLog: [InstallStep: [String]] { run?.log ?? [:] }
  var stepDetail: InstallStep?
  var agentPanelOpen = false
  /// A plan waiting for the user's go-ahead, with its review. Set before anything downloads.
  var planReview: PendingReview?

  struct PendingReview: Identifiable {
    var id: String { model.id }
    var model: CatalogModel
    var plan: ModelPlan
    var verdicts: [PlanVerdict]
    var checking: Bool
  }
  var autonomy = Autonomy(rawValue: UserDefaults.standard.string(forKey: "autonomy") ?? "") ?? .balanced {
    didSet { UserDefaults.standard.set(autonomy.rawValue, forKey: "autonomy") }
  }
  private(set) var failure: InstallFailure?
  private(set) var installing: CatalogModel?
  /// A repair waiting for the user's yes or no.
  private(set) var pendingRepair: (operations: [RepairOperation], report: FailureReport)?
  /// How long a repair question waits before it counts as no.
  var approvalMinutes = max(1, UserDefaults.standard.integer(forKey: "approvalMinutes") == 0 ? 10 : UserDefaults.standard.integer(forKey: "approvalMinutes")) {
    didSet { UserDefaults.standard.set(approvalMinutes, forKey: "approvalMinutes") }
  }
  /// Re-downloads over this many GB ask first (except in Hands-off).
  var askAboveGB = UserDefaults.standard.integer(forKey: "askAboveGB") == 0 ? 10 : UserDefaults.standard.integer(forKey: "askAboveGB") {
    didSet { UserDefaults.standard.set(askAboveGB, forKey: "askAboveGB") }
  }
  private var repairAnswer: CheckedContinuation<Bool, Never>?
  /// Whether the repair agent (OpenRouter) is connected. The key itself never leaves the Keychain.
  let agentStore = AgentStore()
  private(set) var agents: [AgentProfile] = AgentStore().all()
  private(set) var activeAgentID = UserDefaults.standard.string(forKey: "activeAgent") ?? AgentProfile.builtIn.id
  private(set) var agentKeys: Set<String> = []
  var activeAgent: AgentProfile { agents.first { $0.id == activeAgentID } ?? .builtIn }
  /// Whether the chosen agent has a key, so it can supervise installs. Checks existence only; never reads the key.
  var agentOn: Bool { agentKeys.contains(activeAgent.id) }
  var errorMessage: String?
  private(set) var workspace = WorkspaceStore.Snapshot()
  private(set) var generating = false

  private let pipeline = InstallPipeline()
  private let store = ModelStore()
  let tokenCounter = TokenCounter()
  /// Token counters, refreshed whenever one changes.
  private(set) var tokenCounts: [TokenCount] = []
  private var countedParts: Set<String> = []
  /// Tokens in the context on each session's last model call, for the indicator.
  private(set) var contextUsed: [UUID: Int] = [:]
  /// Sessions whose older turns were summarised: the next message carries the task and decisions again.
  private var needsPin: Set<UUID> = []

  /// How full a session's context is, once the engine has reported a model call.
  func contextMeter(for sessionId: UUID) -> ContextMeter? {
    guard let used = contextUsed[sessionId] else { return nil }
    return ContextMeter(used: used, context: active?.config.context ?? ModelPlanner.preferredContext)
  }
  private var turnReportedUsage = false
  /// What the last check of each installed model found, and the progress of checks still running.
  private(set) var integrity: [String: Integrity] = [:]
  private(set) var verifying: [String: Double] = [:]
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
      resumable = runStore.unfinished(installed: Set(installed.map(\.id)))
      refreshAgents()
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

  /// Where new projects are created: a visible folder in Documents.
  static var projectsRoot: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("AGENTGATE Projects", isDirectory: true)
  }

  /// Creates a project with a new folder of the same name.
  func createProject(named name: String) -> Bool {
    do {
      let valid = try WorkspaceStore.validName(name)
      let folder = Self.projectsRoot.appendingPathComponent(valid.replacingOccurrences(of: "/", with: "-"), isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      return add(Project(id: UUID(), name: valid, createdAt: Date(), folder: folder.path))
    } catch {
      errorMessage = String(describing: error)
      return false
    }
  }

  /// Opens an existing folder as a project. Asks which folder.
  func openFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Open"
    panel.message = "Choose the folder this project works in."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    if let existing = workspace.projects.first(where: { $0.folder == url.path }) {
      route = .project(existing.id)
      return
    }
    do {
      _ = add(Project(id: UUID(), name: try WorkspaceStore.validName(String(url.lastPathComponent.prefix(80))),
                      createdAt: Date(), folder: url.path))
    } catch {
      errorMessage = String(describing: error)
    }
  }

  private func add(_ project: Project) -> Bool {
    workspace.projects.append(project)
    do {
      try persist()
      route = .project(project.id)
      return true
    } catch {
      errorMessage = String(describing: error)
      return false
    }
  }

  /// Switches an existing session to another installed model and loads it.
  func switchModel(of sessionId: UUID, to model: InstalledModel) {
    guard let index = workspace.sessions.firstIndex(where: { $0.id == sessionId }),
          workspace.sessions[index].modelId != model.id else { return }
    workspace.sessions[index].modelId = model.id
    workspace.sessions[index].modelName = model.name
    do { try persist() } catch { errorMessage = String(describing: error) }
    if let entry = catalog?.model(model.id) { select(entry) }
  }

  func startSession(in project: UUID, with model: InstalledModel) {
    let session = Session(
      id: UUID(), projectId: project, modelId: model.id, modelName: model.name, createdAt: Date(), messages: [])
    workspace.sessions.append(session)
    do { try persist() } catch { errorMessage = String(describing: error) }
    route = .session(session.id)
    if active?.id != model.id, let entry = catalog?.model(model.id) { select(entry) }
  }

  /// Starts a chat in the project with a CI failure as the task. Uses the loaded model, or the first installed one.
  func fixWithAgent(in project: UUID, task: String) {
    guard let model = active ?? installed.first else {
      errorMessage = "Install a model first."
      return
    }
    startSession(in: project, with: model)
    guard case .session(let id) = route else { return }
    send(task, in: id)
  }

  private func persist() throws { try workspaceStore.save(workspace) }

  // MARK: Tokens

  /// The supervising agent, with its replies counted as cloud usage.
  private func supervisor() -> AgentAssistant {
    var assistant = AgentAssistant(profile: activeAgent)
    let model = activeAgent.model, name = "\(activeAgent.name) · \(activeAgent.model)"
    assistant.onUsage = { usage in
      Task { @MainActor in self.countTokens(usage, model: model, name: name, location: .cloud) }
    }
    return assistant
  }

  func countTokens(_ usage: TokenUsage?, model: String, name: String, location: ModelLocation) {
    do { try tokenCounter.record(usage, model: model, name: name, location: location) }
    catch { errorMessage = "The token counter could not be saved: \(error)" }
    tokenCounts = tokenCounter.all()
  }

  func resetTokens(_ count: TokenCount) {
    do { try tokenCounter.reset(model: count.model, location: count.location) }
    catch { errorMessage = String(describing: error) }
    tokenCounts = tokenCounter.all()
  }

  func loadTokenCounts() { tokenCounts = tokenCounter.all() }

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

  func catalogModel(_ id: String) -> CatalogModel? { catalog?.model(id) }

  /// Install entry point for the UI: an installed model loads at once; a new one shows its plan and review first.
  func requestInstall(_ model: CatalogModel) {
    guard !installed.contains(where: { $0.id == model.id }), let profile,
          case .compatible(let plan) = ModelPlanner.plan(model, for: profile, limits: InstallPipeline.supported) else {
      select(model)
      return
    }
    let onBattery = PowerState.onBattery()
    let rules = PlanReview.rules(plan, profile: profile, onBattery: onBattery)
    planReview = PendingReview(model: model, plan: plan, verdicts: [rules], checking: agentOn)
    guard agentOn else { return }
    let input = PlanReviewInput(model: model.name, plan: plan, profile: profile, onBattery: onBattery, task: nil)
    let ids = (catalog?.models ?? []).filter { option($0).plan != nil }.map(\.id)
    let assistant = AgentAssistant(profile: activeAgent)
    Task {
      let raw = try? await assistant.reviewPlan(input, allowedModelIds: ids)
      guard planReview?.id == model.id else { return }
      let agent = raw.flatMap { PlanReview.parseAgent($0, allowedModelIds: Set(ids)) }
      planReview?.verdicts = PlanReview.combine(rules: rules, agent: agent)
      planReview?.checking = false
    }
  }

  func confirmReview() {
    guard let review = planReview else { return }
    planReview = nil
    select(review.model)
  }

  func cancelReview() { planReview = nil }

  func reviewInstead(_ model: CatalogModel) {
    planReview = nil
    requestInstall(model)
  }

  /// Installs the model if needed, then loads it. One install or load at a time.
  @discardableResult
  func select(_ model: CatalogModel) -> Task<Bool, Never>? {
    if let installTask, installing != nil { return installTask }
    failure = nil
    let fresh = !installed.contains { $0.id == model.id }
    run = InstallRun(modelId: model.id, modelName: model.name)
    resumable.removeAll { $0.modelId == model.id }
    installing = model
    stopRuntime()
    let task = Task { () -> Bool in
      defer { installing = nil }
      do {
        let report: @Sendable (InstallUpdate) -> Void = { update in
          Task { @MainActor in
            self.update = update
            self.log(update, persist: fresh)
          }
        }
        if let done = installed.first(where: { $0.id == model.id }) {
          runtime = try await pipeline.load(done, update: report)
          active = done
        } else {
          var runner = RepairRunner(
            assistant: agentOn ? supervisor() : nil, autonomy: autonomy,
            approvalTimeout: .seconds(approvalMinutes * 60)
          ) { operation, failure in
            await self.askToRepair([operation], failure)
          }
          runner.approveBatch = { operations, failure in await self.askToRepair(operations, failure) }
          runner.askAboveBytes = UInt64(askAboveGB) * MemoryBudget.gib
          let (done, runtime) = try await runner.install(model, update: report)
          self.runtime = runtime
          installed = try store.list()
          active = done
          runStore.remove(model.id)
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
      // An installed model that fails to load may have a damaged file: check it, so the message can say so.
      if !fresh, var shown = failure, let done = installed.first(where: { $0.id == model.id }),
         let result = try? await FileIntegrityCheck(store: store).verify(done) {
        integrity[done.id] = result
        shown.message += result == .intact
          ? " The model file was checked and is intact." : " " + result.message(for: done)
        failure = shown
      }
      if fresh, var record = run {
        record.failure = failure?.message
        run = record
        saveRun(record)
      }
      return false
    }
    installTask = task
    return task
  }

  private func refreshAgents() {
    agents = agentStore.all()
    agentKeys = Set(agents.filter(AgentStore.isConnected).map(\.id))
    providerKeys = Set(Providers.all.filter { $0.keychain.exists() }.map(\.id))
  }

  /// Providers with a saved key. Existence only; keys are never read into the app's state.
  private(set) var providerKeys: Set<String> = []

  /// Checks a key with its provider, then saves it in the Keychain. Returns what to tell the user.
  func saveProviderKey(_ provider: Provider, key: String) async -> (saved: Bool, message: String) {
    let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return (false, "Paste a key first.") }
    switch await Providers.verify(provider, key: key) {
    case .rejected: return (false, "\(provider.name) rejected this key.")
    case .unreachable(let why): return (false, "Not saved: \(why) Try again when online.")
    case .valid:
      do {
        try provider.keychain.save(key)
        refreshAgents()
        return (true, "\(provider.name) key saved.")
      } catch {
        return (false, String(describing: error))
      }
    }
  }

  func removeProviderKey(_ provider: Provider) {
    do {
      try provider.keychain.delete()
      refreshAgents()
    } catch {
      errorMessage = String(describing: error)
    }
  }

  /// Adds an agent on any OpenAI-compatible provider and makes it the active one.
  func addAgent(name: String, address: String, model: String, key: String) -> Bool {
    do {
      let profile = try AgentProfile.custom(name: name, baseURL: address, model: model)
      try agentStore.add(profile, key: key.trimmingCharacters(in: .whitespacesAndNewlines))
      refreshAgents()
      selectAgent(profile.id)
      return true
    } catch {
      errorMessage = String(describing: error)
      return false
    }
  }

  func selectAgent(_ id: String) {
    guard agents.contains(where: { $0.id == id }) else { return }
    activeAgentID = id
    UserDefaults.standard.set(id, forKey: "activeAgent")
  }

  func removeAgent(_ id: String) {
    do {
      try agentStore.remove(id)
      if activeAgentID == id { selectAgent(AgentProfile.builtIn.id) }
      refreshAgents()
    } catch {
      errorMessage = String(describing: error)
    }
  }

  /// Keeps what a step said, and for a new install saves the record: on every step change, and at most every
  /// three seconds during a download.
  private func log(_ update: InstallUpdate, persist: Bool) {
    guard var record = run else { return }
    let stepChanged = record.step != update.step
    record.record(update)
    run = record
    if persist, stepChanged || Date().timeIntervalSince(lastRunSave) > 3 { saveRun(record) }
  }

  private func saveRun(_ record: InstallRun) {
    do {
      try runStore.save(record)
      lastRunSave = Date()
    } catch {
      errorMessage = "The install record could not be saved: \(error)"
    }
  }

  /// Picks up an install that stopped. The download resumes from its partial file.
  func resume(_ record: InstallRun) {
    guard let model = catalog?.model(record.modelId) else { discard(record); return }
    select(model)
  }

  /// Forgets an install that stopped, and removes its incomplete files (never a finished model's).
  func discard(_ record: InstallRun) {
    runStore.remove(record.modelId)
    resumable.removeAll { $0.modelId == record.modelId }
    let folder = store.folder(record.modelId)
    if (try? store.load(record.modelId)) == nil, FileManager.default.fileExists(atPath: folder.path) {
      do { try FileManager.default.removeItem(at: folder) } catch { errorMessage = String(describing: error) }
    }
  }

  func cancelInstall() {
    answerRepair(false)
    installTask?.cancel()
  }

  /// Shows the question in the bar. If the runner stops waiting (timeout), the question is taken down as a no.
  private func askToRepair(_ operations: [RepairOperation], _ report: FailureReport) async -> Bool {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        pendingRepair = (operations, report)
        repairAnswer = continuation
      }
    } onCancel: {
      Task { @MainActor in self.answerRepair(false) }
    }
  }

  func answerRepair(_ approved: Bool) {
    pendingRepair = nil
    repairAnswer?.resume(returning: approved)
    repairAnswer = nil
  }

  func dismissFailure() { failure = nil }

  func dismissUpdate() { update = nil }

  /// Re-hashes an installed model's file and records whether it is intact.
  func verify(_ model: InstalledModel) {
    guard verifying[model.id] == nil else { return }
    verifying[model.id] = 0
    integrity[model.id] = nil
    let id = model.id
    Task {
      do {
        let result = try await FileIntegrityCheck(store: store).verify(model) { fraction in
          Task { @MainActor in if self.verifying[id] != nil { self.verifying[id] = fraction } }
        }
        integrity[id] = result
      } catch {
        errorMessage = "\(model.name) could not be checked: \(error)"
      }
      verifying[id] = nil
    }
  }

  /// Removes a damaged model and installs it again from the catalog.
  func reinstall(_ model: InstalledModel) {
    guard let entry = catalog?.model(model.id) else {
      errorMessage = "\(model.name) is no longer in the catalog, so it cannot be reinstalled. Remove it instead."
      return
    }
    remove(model)
    integrity[model.id] = nil
    select(entry)
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
      errorMessage = String(describing: error)
    }
  }

  func stopRuntime() {
    runtime?.stop()
    runtime = nil
  }

  // MARK: Advisor

  private(set) var suggestions: [ModelSuggestion] = []
  private(set) var advisorNote: String?
  private(set) var advising = false
  /// Local first; cloud models are offered only when no local model meets the task, and only from a connected key.
  private(set) var taskRoute: RouteAdvice = .local
  private var cloudOffers: [CloudOffer]?
  /// The cloud model the user picked for a task. Picking sends nothing anywhere.
  private(set) var chosenCloud: CloudOffer?

  func chooseCloud(_ offer: CloudOffer?) { chosenCloud = offer }

  /// Suggests models for a task. The agent (if on) reads the task; fixed code ranks the models.
  func suggestModels(for task: String) {
    let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !task.isEmpty, let catalog, let profile else { return }
    advising = true
    Task {
      defer { advising = false }
      var needs = TaskNeeds.fromKeywords(task)
      var source = "Read by fixed rules."
      if agentOn {
        do {
          needs = try await supervisor().needs(for: task)
          source = "Read by \(activeAgent.name)."
        } catch {
          source = "The agent's answer could not be used, so fixed rules read it."
        }
      }
      suggestions = ModelAdvisor.suggest(catalog, for: profile, installed: installed, needs: needs)
      chosenCloud = nil
      taskRoute = .local
      if TaskRouter.shortfall(needs: needs, local: suggestions) != nil, providerKeys.contains(Providers.openRouter.id) {
        // The price list is public; fetching it sends no key and nothing about the task.
        if cloudOffers == nil { cloudOffers = try? await CloudCatalog.fetchOpenRouter() }
        taskRoute = TaskRouter.advise(needs: needs, local: suggestions, connected: cloudOffers ?? [])
      } else if let reason = TaskRouter.shortfall(needs: needs, local: suggestions) {
        taskRoute = .cloudSuggested(reason: reason, offers: [])
      }
      let wants = [needs.tools ? "tools" : nil, needs.longContext ? "long context" : nil, needs.priority == .balanced ? nil : needs.priority.rawValue]
        .compactMap { $0 }.joined(separator: ", ")
      advisorNote = (wants.isEmpty ? "No special needs." : "Needs \(wants).") + " " + source + " Scores are estimates until measured on this Mac."
    }
  }

  // MARK: Agent

  /// The turn in progress: every step the agent took, shown as it happens and saved with the answer.
  private(set) var transcript = Transcript()
  /// When the turn in progress started, for its clock.
  private(set) var turnStarted: Date?
  /// The question shown to the user now. Others asked meanwhile wait in `queuedPermissions`.
  private(set) var pendingPermission: AgentEvent.Permission?
  private var queuedPermissions: [AgentEvent.Permission] = []
  /// Questions already reviewed, so one that arrives by the event stream and by the poll is checked once.
  private var reviewedPermissions: Set<String> = []
  let securityLog = SecurityLog()
  private(set) var securityEntries: [SecurityEntry] = []
  private var agent: AgentServer?
  private var eventTask: Task<Void, Never>?
  private var streamingSession: UUID?
  private var agentConnected = false
  private var loggedRefusals: Set<String> = []
  /// Errors and stops the app adds under the answer.
  private var notes = ""
  /// The file of the latest edit, exactly as the model wrote it, for the policy check. Never the
  /// redacted text shown on screen: that would hide a path outside the project.
  private var lastEditPath: String?

  /// Sends a task in a session. The agent harness runs it in the project's folder with the session's model.
  func send(_ text: String, in sessionId: UUID) {
    guard !generating, let index = workspace.sessions.firstIndex(where: { $0.id == sessionId }) else { return }
    let session = workspace.sessions[index]
    guard let folder = project(session.projectId)?.folder else {
      errorMessage = "This project has no folder. Open a folder to let the agent work."
      return
    }
    workspace.sessions[index].messages.append(ChatMessage(role: .user, content: text))
    workspace.sessions[index].messages.append(ChatMessage(role: .assistant, content: ""))
    generating = true
    streamingSession = sessionId
    transcript = Transcript()
    turnStarted = Date()
    notes = ""
    lastEditPath = nil
    queuedPermissions = []
    reviewedPermissions = []
    Task {
      do {
        // Load the session's model, or reload it if its engine has died since the last message.
        if active?.id != session.modelId || runtime?.isRunning != true {
          guard let entry = catalog?.model(session.modelId), let task = select(entry), await task.value else {
            throw AgentError.missingBinary("The model for this session could not be loaded.")
          }
        }
        guard let runtime else { return }
        let server = try await agentServer(folder: URL(fileURLWithPath: folder), runtime: runtime)
        var agentId = workspace.sessions.first { $0.id == sessionId }?.agentSession
        if agentId == nil {
          agentId = try await server.client.createSession(title: String(text.prefix(60)))
          if let i = workspace.sessions.firstIndex(where: { $0.id == sessionId }) { workspace.sessions[i].agentSession = agentId }
        }
        // Wait for the event stream, so no question from the agent is missed.
        for _ in 0..<100 where !agentConnected { try await Task.sleep(nanoseconds: 50_000_000) }
        var outgoing = text
        if needsPin.remove(sessionId) != nil,
           let pinned = PinnedContext.from(userMessages: session.messages.filter { $0.role == .user }.map(\.content) + [text]) {
          outgoing = pinned.preamble() + "\n\n" + text
        }
        try await server.client.prompt(session: agentId!, text: outgoing, model: session.modelId)
        try await watchForQuestions(server)
      } catch {
        append("\(error)", to: sessionId)
        finishTurn()
      }
    }
  }

  /// A backstop for the event stream: while a turn runs, look for questions every two seconds. They go
  /// through the same review as streamed ones. A turn is capped at 30 minutes.
  private func watchForQuestions(_ server: AgentServer) async throws {
    for _ in 0..<900 where generating {
      try await Task.sleep(nanoseconds: 2_000_000_000)
      // A failed poll is not fatal: the event stream is the primary path, and a dead harness ends it.
      guard let pending = try? await server.client.pendingPermissions() else { continue }
      for permission in pending where generating { review(permission) }
    }
  }

  func stopAgent() {
    guard generating, let id = streamingSession,
          let agentId = workspace.sessions.first(where: { $0.id == id })?.agentSession, let agent else { return }
    Task { try? await agent.client.abort(session: agentId) }
  }

  /// Answers the agent's question about a command or edit. Anything but a yes is a no.
  func answerPermission(allow: Bool) {
    guard let permission = pendingPermission, let agent else { return }
    dismiss(permission.id)
    // Check again at the moment of approval: by now the file the agent means to edit is known.
    if allow, case .block(let rule, _) = verdict(for: permission, final: true) {
      block(permission, rule: rule, agent: agent)
      return
    }
    record(permission.tool, permission.detail, allow ? .allowed : .deniedByUser, rule: "")
    // The step's clock starts now: the time spent waiting for the user is not the command's.
    if allow { transcript.approved(callID: permission.callID) }
    Task {
      do { try await agent.client.reply(permission: permission.id, allow: allow) }
      catch { errorMessage = String(describing: error) }
    }
  }

  // MARK: Security

  private var streamingFolder: URL? {
    guard let id = streamingSession,
          let folder = workspace.sessions.first(where: { $0.id == id }).flatMap({ project($0.projectId)?.folder })
    else { return nil }
    return URL(fileURLWithPath: folder)
  }

  /// The policy's answer for a request. Edits name their file only in the tool call, so for those the
  /// answer can be unknown until then; at the final check an unknown target counts as blocked.
  private func verdict(for permission: AgentEvent.Permission, final: Bool) -> ToolPolicy.Verdict? {
    guard let folder = streamingFolder else {
      return .block(rule: "unknown-project", reason: "The project folder could not be determined.")
    }
    if permission.tool == "bash" { return ToolPolicy.evaluate(tool: "bash", detail: permission.detail, folder: folder) }
    guard ["edit", "write", "patch", "multiedit"].contains(permission.tool) else { return .allow }
    guard let path = lastEditPath else {
      return final ? .block(rule: "unknown-target", reason: "The file to edit could not be determined.") : nil
    }
    return ToolPolicy.evaluate(tool: "edit", detail: path, folder: folder)
  }

  /// A question is answered or gone: show the next one waiting, if any.
  private func dismiss(_ id: String) {
    queuedPermissions.removeAll { $0.id == id }
    if pendingPermission?.id == id {
      pendingPermission = queuedPermissions.isEmpty ? nil : queuedPermissions.removeFirst()
    }
  }

  /// A new question from the agent: refuse it at once if a rule forbids it, otherwise ask the user.
  /// Every question comes through here exactly once, whether it arrived by the stream or the poll.
  private func review(_ permission: AgentEvent.Permission) {
    guard reviewedPermissions.insert(permission.id).inserted else { return }
    // Our check of every call first (J3): paths, sizes, command rules. A refusal tells the model why.
    if let agent {
      guard let folder = streamingFolder else {
        block(permission, rule: "unknown-project", agent: agent, message: "The project folder could not be determined, so nothing can run.")
        return
      }
      if let rejection = ToolCallCheck.check(permission, folder: folder) {
        block(permission, rule: rejection.rule, agent: agent, message: rejection.message)
        return
      }
      // Reads that passed the check run without asking the user.
      if ToolCallCheck.readOnly.contains(permission.tool) {
        transcript.approved(callID: permission.callID)
        Task { try? await agent.client.reply(permission: permission.id, allow: true) }
        return
      }
    }
    if case .block(let rule, _)? = verdict(for: permission, final: false), let agent {
      block(permission, rule: rule, agent: agent)
    } else if pendingPermission == nil {
      pendingPermission = permission
    } else {
      queuedPermissions.append(permission)
    }
  }

  private func block(_ permission: AgentEvent.Permission, rule: String, agent: AgentServer, message: String? = nil) {
    // Only this question is answered; another one shown to the user stays.
    dismiss(permission.id)
    record(permission.tool, permission.detail, .blocked, rule: rule)
    let feedback = message ?? "Refused by AGENTGATE (\(rule)). Do not retry the same call; choose another way that stays inside the project."
    transcript.refuse(
      id: "blocked-\(permission.id)", tool: permission.tool, detail: displayed(permission.detail),
      reason: "Blocked by the rule \(rule). The agent was told: \(feedback)", callID: permission.callID)
    showTranscript()
    Task { try? await agent.client.reply(permission: permission.id, allow: false, message: feedback) }
  }

  /// A tool returned text that reads like an instruction to the model: stop the turn and say so.
  private func stopForInjection(_ tool: AgentEvent.Tool) {
    record(tool.name, tool.detail, .stopped, rule: "instruction-in-tool-output")
    if let id = streamingSession { append("\n\nStopped: what \(tool.name) returned looked like instructions to the model. Review it before continuing.", to: id) }
    stopAgent()
  }

  private func record(_ tool: String, _ detail: String, _ outcome: SecurityEntry.Outcome, rule: String) {
    let folder = streamingFolder
    let clean = folder.map { Redaction.clean(detail, root: $0, label: "<project>") } ?? detail
    let name = streamingSession.flatMap { id in workspace.sessions.first { $0.id == id } }
      .flatMap { project($0.projectId)?.name } ?? ""
    do {
      try securityLog.append(SecurityEntry(
        date: Date(), project: name, tool: tool, detail: String(clean.prefix(200)), outcome: outcome, rule: rule))
      securityEntries = securityLog.entries()
    } catch {
      errorMessage = String(describing: error)
    }
  }

  func loadSecurityEntries() { securityEntries = securityLog.entries() }

  private func agentServer(folder: URL, runtime: LlamaRuntime) async throws -> AgentServer {
    if let agent, agent.isRunning, agent.folder == folder, agent.engineKey == runtime.apiKey { return agent }
    stopAgentServer()
    agentConnected = false
    let server = try await AgentServer.start(
      folder: folder, engineURL: runtime.baseURL, engineKey: runtime.apiKey, model: runtime.alias,
      // The harness must know the model's real context to size its own compaction.
      context: active?.config.context ?? ModelPlanner.preferredContext)
    agent = server
    eventTask = Task { [weak self] in
      do {
        for try await event in server.client.events() { self?.handle(event) }
      } catch {
        self?.errorMessage = "Lost the connection to the agent: \(error)"
      }
      self?.finishTurn()
    }
    return server
  }

  func stopAgentServer() {
    eventTask?.cancel()
    eventTask = nil
    agent?.stop()
    agent = nil
  }

  private func handle(_ event: AgentEvent) {
    transcript.apply(event, clean: displayed)
    switch event {
    case .tool(let tool):
      if ["edit", "write", "patch", "multiedit"].contains(tool.name), !tool.detail.isEmpty { lastEditPath = tool.detail }
      if tool.status == "completed", ToolPolicy.looksLikeInjection(tool.output) { stopForInjection(tool) }
      // The harness refuses some requests by itself (outside the project, web fetches). Log those too,
      // but not its echo of an answer already logged here ("rejected permission": our refusal or the user's no).
      let error = tool.error ?? ""
      let lowered = (tool.output + " " + error).lowercased()
      if tool.status == "error", !error.contains("rejected permission"),
         ["denied", "rejected", "not allowed", "permission"].contains(where: lowered.contains),
         loggedRefusals.insert(tool.id).inserted {
        record(tool.name, tool.detail, .blocked, rule: "harness-refused")
      }
    case .permission(let permission): review(permission)
    case .usage(let partID, let usage):
      guard countedParts.insert(partID).inserted, let id = streamingSession,
            let session = workspace.sessions.first(where: { $0.id == id }) else { break }
      turnReportedUsage = true
      countTokens(usage, model: session.modelId, name: session.modelName, location: .local)
      if let usage { contextUsed[id] = usage.prompt + usage.generated }
    case .compacted(let partID):
      guard countedParts.insert(partID).inserted, let id = streamingSession else { break }
      // Visible to the user, and the task and decisions go again with the next message.
      needsPin.insert(id)
      append("\n\n_Older turns were summarised to fit the context. The task and decisions are kept and sent again._\n\n", to: id)
    case .permissionReplied(let id): dismiss(id)
    case .connected: agentConnected = true
    case .idle: finishTurn()
    case .failed(let message):
      if let id = streamingSession { append("\n\nError: \(message)", to: id) }
      finishTurn()
    default: break
    }
    showTranscript()
  }

  /// Text from a tool as it is shown and saved: keys hidden, the project folder written as ".". Other
  /// paths stay: a path outside the project is exactly what the user needs to see.
  private func displayed(_ text: String) -> String {
    guard let folder = streamingFolder else { return Redaction.secrets(text) }
    return Redaction.secrets(text.replacingOccurrences(of: folder.path, with: "."))
  }

  /// Puts the turn so far into the session's last message: the steps, and the answer text.
  private func showTranscript(usage: TurnUsage? = nil) {
    guard let id = streamingSession, let index = workspace.sessions.firstIndex(where: { $0.id == id }),
          let last = workspace.sessions[index].messages.indices.last else { return }
    let steps = transcript.steps
    workspace.sessions[index].messages[last].steps = steps
    workspace.sessions[index].messages[last].content = transcript.answer + notes
    if let usage { workspace.sessions[index].messages[last].usage = usage }
  }

  private func finishTurn() {
    guard generating else { return }
    // A turn whose replies carried no usage at all is noted as unreported, never guessed.
    if !turnReportedUsage, let id = streamingSession, let session = workspace.sessions.first(where: { $0.id == id }) {
      countTokens(nil, model: session.modelId, name: session.modelName, location: .local)
    }
    turnReportedUsage = false
    transcript.finish(seconds: turnStarted.map { Date().timeIntervalSince($0) } ?? 0)
    showTranscript(usage: transcript.usage)
    generating = false
    pendingPermission = nil
    queuedPermissions = []
    streamingSession = nil
    do { try persist() } catch { errorMessage = String(describing: error) }
  }

  private func append(_ text: String, to sessionId: UUID) {
    guard sessionId == streamingSession else { return }
    notes += text
    showTranscript()
  }
}
