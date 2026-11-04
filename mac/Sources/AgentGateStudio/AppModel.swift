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
  private(set) var stepLog: [InstallStep: [String]] = [:]
  var stepDetail: InstallStep?
  var agentPanelOpen = false
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
    stepLog = [:]
    installing = model
    stopRuntime()
    let task = Task { () -> Bool in
      defer { installing = nil }
      do {
        let report: @Sendable (InstallUpdate) -> Void = { update in
          Task { @MainActor in
            self.update = update
            self.log(update)
          }
        }
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

  /// Keeps what a step said. Download progress replaces its own last line instead of piling up.
  private func log(_ update: InstallUpdate) {
    var lines = stepLog[update.step, default: []]
    if update.step == .download, update.totalBytes > 0, let last = lines.last, last.hasPrefix("Downloading ") {
      lines[lines.count - 1] = update.message
    } else if lines.last != update.message {
      lines.append(update.message)
    }
    stepLog[update.step] = Array(lines.suffix(40))
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

  // MARK: Agent

  /// One thing the agent did or asked to do, kept for the activity view.
  struct ActivityItem: Identifiable, Equatable {
    var id: String
    var tool: String
    var detail: String
    var status: String
    var output: String
    var date = Date()
  }

  private(set) var activity: [ActivityItem] = []
  private(set) var pendingPermission: AgentEvent.Permission?
  let securityLog = SecurityLog()
  private(set) var securityEntries: [SecurityEntry] = []
  var activityOpen = false
  private var agent: AgentServer?
  private var eventTask: Task<Void, Never>?
  private var streamingSession: UUID?
  private var agentConnected = false
  private var loggedRefusals: Set<String> = []
  private var parts: [(id: String, messageID: String, text: String)] = []
  private var roles: [String: String] = [:]

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
    thinking = true
    streamingSession = sessionId
    parts = []
    roles = [:]
    activity = []
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
        try await server.client.prompt(session: agentId!, text: text, model: session.modelId)
        try await watchForQuestions(server)
      } catch {
        append("\(error)", to: sessionId)
        finishTurn()
      }
    }
  }

  /// A backstop for the event stream: while a turn runs, look for a pending question every two seconds.
  /// A turn is capped at 30 minutes.
  private func watchForQuestions(_ server: AgentServer) async throws {
    for _ in 0..<900 where generating {
      try await Task.sleep(nanoseconds: 2_000_000_000)
      if pendingPermission == nil, let first = try await server.client.pendingPermissions().first {
        pendingPermission = first
      }
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
    pendingPermission = nil
    // Check again at the moment of approval: by now the file the agent means to edit is known.
    if allow, case .block(let rule, _) = verdict(for: permission, final: true) {
      block(permission, rule: rule, agent: agent)
      return
    }
    record(permission.tool, permission.detail, allow ? .allowed : .deniedByUser, rule: "")
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
    let editing = ["edit", "write", "patch", "multiedit"]
    guard let path = activity.last(where: { editing.contains($0.tool) && !$0.detail.isEmpty })?.detail else {
      return final ? .block(rule: "unknown-target", reason: "The file to edit could not be determined.") : nil
    }
    return ToolPolicy.evaluate(tool: "edit", detail: path, folder: folder)
  }

  /// A new question from the agent: refuse it at once if a rule forbids it, otherwise ask the user.
  private func review(_ permission: AgentEvent.Permission) {
    if case .block(let rule, _)? = verdict(for: permission, final: false), let agent {
      block(permission, rule: rule, agent: agent)
    } else {
      pendingPermission = permission
    }
  }

  private func block(_ permission: AgentEvent.Permission, rule: String, agent: AgentServer) {
    pendingPermission = nil
    record(permission.tool, permission.detail, .blocked, rule: rule)
    activity.append(ActivityItem(
      id: "blocked-\(permission.id)", tool: permission.tool, detail: permission.detail,
      status: "blocked: \(rule)", output: ""))
    Task { try? await agent.client.reply(permission: permission.id, allow: false) }
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
      folder: folder, engineURL: runtime.baseURL, engineKey: runtime.apiKey, model: runtime.alias)
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
    switch event {
    case .message(let id, let role): roles[id] = role
    case .text(let id, let message, let text):
      if let i = parts.firstIndex(where: { $0.id == id }) { parts[i].text = text } else { parts.append((id, message, text)) }
      showAnswer()
    case .textDelta(let id, let message, let delta):
      if let i = parts.firstIndex(where: { $0.id == id }) { parts[i].text += delta } else { parts.append((id, message, delta)) }
      showAnswer()
    case .tool(let tool):
      let item = ActivityItem(id: tool.id, tool: tool.name, detail: tool.detail, status: tool.status, output: tool.output)
      if let i = activity.firstIndex(where: { $0.id == tool.id }) { activity[i] = item } else { activity.append(item) }
      if tool.status == "completed", ToolPolicy.looksLikeInjection(tool.output) { stopForInjection(tool) }
      // The harness refuses some requests by itself (outside the project, web fetches). Log those too.
      let lowered = tool.output.lowercased()
      if tool.status == "error", ["denied", "rejected", "not allowed", "permission"].contains(where: lowered.contains),
         loggedRefusals.insert(tool.id).inserted {
        record(tool.name, tool.detail, .blocked, rule: "harness-refused")
      }
    case .permission(let permission): review(permission)
    case .connected: agentConnected = true
    case .busy: thinking = true
    case .idle: finishTurn()
    case .failed(let message):
      if let id = streamingSession { append("\n\nError: \(message)", to: id) }
      finishTurn()
    }
  }

  /// The answer is every assistant text part so far; the user's own text echoes back and is skipped.
  private func showAnswer() {
    guard let id = streamingSession, let index = workspace.sessions.firstIndex(where: { $0.id == id }),
          let last = workspace.sessions[index].messages.indices.last else { return }
    let text = parts.filter { roles[$0.messageID] == "assistant" }.map(\.text).joined(separator: "\n\n")
    guard !text.isEmpty else { return }
    thinking = false
    workspace.sessions[index].messages[last].content = text
  }

  private func finishTurn() {
    guard generating else { return }
    generating = false
    thinking = false
    pendingPermission = nil
    streamingSession = nil
    do { try persist() } catch { errorMessage = String(describing: error) }
  }

  private func append(_ text: String, to sessionId: UUID) {
    guard let index = workspace.sessions.firstIndex(where: { $0.id == sessionId }),
          let last = workspace.sessions[index].messages.indices.last else { return }
    workspace.sessions[index].messages[last].content += text
  }
}
