import AgentGateCore
import SwiftUI

struct SessionPage: View {
  @Environment(AppModel.self) private var app
  let sessionId: UUID
  @State private var draft = ""
  /// The next message goes to the plan agent, which looks and writes a plan but changes nothing.
  @State private var planFirst = false
  @FocusState private var composerFocused: Bool
  @AppStorage("terminalOpen") private var terminalOpen = false

  var body: some View {
    if let session = app.session(sessionId), let project = app.project(session.projectId) {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Button { app.route = .project(project.id) } label: { Text("← \(project.name)").font(.system(size: 13)) }
            .buttonStyle(.plain).foregroundStyle(Theme.muted)
          Spacer()
          if let meter = app.contextMeter(for: session.id) {
            HStack(spacing: 6) {
              ProgressView(value: meter.fraction).frame(width: 60)
                .tint(meter.isNearlyFull ? Theme.danger : Theme.accent)
              Text(meter.label).font(.system(size: 11)).foregroundStyle(Theme.muted).monospacedDigit()
            }
            .help(meter.isNearlyFull
              ? "Nearly full: older turns will be summarised soon. The task and decisions are kept."
              : "How much of the model's context the last step used.")
            .accessibilityElement(children: .combine)
            .accessibilityLabel(meter.label)
          }
          if let folder = project.folder {
            Label((folder as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
              .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            Button { terminalOpen.toggle() } label: {
              Label("Terminal", systemImage: "terminal").font(.system(size: 12))
                .foregroundStyle(terminalOpen ? Theme.accent : Theme.muted)
            }
            .buttonStyle(.plain).keyboardShortcut("`", modifiers: .control)
            .help("Open a terminal in this project's folder (⌃`)")
          }
        }
        if let goal = session.goal {
          GoalBanner(sessionId: session.id, goal: goal)
        }
        if terminalOpen, let folder = project.folder {
          VSplitView {
            conversation(session).frame(minHeight: 280).layoutPriority(1)
            TerminalPane(folder: folder)
              .padding(.horizontal, 10).padding(.vertical, 8)
              .background(Theme.bg)
              .clipShape(RoundedRectangle(cornerRadius: 10))
              .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
              .frame(minHeight: 120, idealHeight: 220, maxHeight: 420)
              .padding(.top, 8)
              .id(folder)
          }
        } else {
          conversation(session)
        }
      }
      .padding(.horizontal, 42).padding(.top, 28).padding(.bottom, 20)
      .frame(maxWidth: 860, maxHeight: .infinity, alignment: .topLeading)
      .frame(maxWidth: .infinity, alignment: .center)
      .task(id: project.id) { app.scanRepo(project.id) }
    } else {
      Text("This session no longer exists.").foregroundStyle(Theme.muted)
    }
  }

  private func modelState(_ session: Session) -> String {
    if app.active?.id == session.modelId { return "Local · loaded" }
    if app.installing?.id == session.modelId { return "Local · loading…" }
    return "Local · loads when you send a task"
  }

  private func conversation(_ session: Session) -> some View {
    VStack(spacing: 0) {
      if session.messages.isEmpty {
        VStack(spacing: 18) {
          IconTile(symbol: "sparkle", size: 56)
          VStack(spacing: 6) {
            Text("What are we working on?").font(.system(size: 17, weight: .semibold))
            Text("Ask for one change, or give the agent a goal and it works in rounds until it is done.")
              .font(.system(size: 13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
          }
          SuggestionChips(
            testCommand: app.repoSummaries[session.projectId]?.testCommand,
            disabled: !app.agentOn || app.generating,
            send: { app.send($0, in: session.id) },
            startGoal: { app.startGoal($0, inSession: session.id) })
            .padding(.top, 6)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
              ForEach(session.messages) { message in
                let live = app.generating && message.id == session.messages.last?.id
                Group {
                  if message.role == .assistant {
                    AgentTurnView(message: message, live: live)
                  } else {
                    UserTurn(message: message)
                  }
                }
                .id(message.id)
              }
              Color.clear.frame(height: 1).id("bottom")
            }
            .padding(22)
          }
          // Follow the turn as it grows: new text, new steps, new output, a question.
          .onChange(of: session.messages.last) { proxy.scrollTo("bottom", anchor: .bottom) }
          // A chat opens at its latest message, like any messages app.
          .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
          .onChange(of: app.pendingPermission?.id) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
      }
      composer(session)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)

  }

  private func composer(_ session: Session) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      if awaitingPlanApproval(session) {
        HStack(spacing: 10) {
          Image(systemName: "list.bullet.clipboard").foregroundStyle(Theme.accent)
          VStack(alignment: .leading, spacing: 2) {
            Text("The plan is ready. Nothing has changed yet.").font(.system(size: 13, weight: .medium))
            Text("Carry it out as written, or type what to change and send it with Plan first on.")
              .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
          }
          Spacer()
          Button("Revise") { planFirst = true; composerFocused = true }.buttonStyle(SubtleButtonStyle())
          Button { carryOutPlan() } label: { Label("Carry out", systemImage: "play.fill") }
            .buttonStyle(PrimaryButtonStyle()).disabled(!app.agentOn)
        }
        .padding(.bottom, 4)
      }
      if !app.agentOn {
        HStack(spacing: 10) {
          Image(systemName: "key").foregroundStyle(Theme.accent)
          Text("Add an API key to turn on the agent, then start working.").font(.system(size: 13))
          Spacer()
          Button("Add a key") { app.route = .profile }.buttonStyle(PrimaryButtonStyle())
        }
      }
      let suggestions = mentionSuggestions(session)
      if !suggestions.isEmpty {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(suggestions, id: \.self) { path in
            Button { insertMention(path) } label: {
              HStack(spacing: 8) {
                Image(systemName: "doc").font(.system(size: 11)).foregroundStyle(Theme.muted)
                Text(path).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer()
              }
              .padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raised))
      }
      TextField("Task", text: $draft, prompt: Text(""), axis: .vertical)
        .inputHint("Ask anything about your project… Type @ to mention a file.", when: draft.isEmpty)
        .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(3...8)
        .accessibilityLabel("Task")
        .focused($composerFocused)
        .onAppear { composerFocused = true }
        .onSubmit { send() }
      HStack {
        modelMenu(session)
        Text(modelState(session)).font(.system(size: 11)).foregroundStyle(Theme.muted)
        Spacer()
        Button { planFirst.toggle() } label: { Label("Plan first", systemImage: "list.bullet.clipboard") }
          .buttonStyle(SubtleButtonStyle())
          .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(planFirst ? Theme.accent : .clear, lineWidth: 1.5))
          .foregroundStyle(planFirst ? Theme.accent : Theme.text)
          .help("The agent looks and writes a plan, changing nothing, then you choose to carry it out")
          .accessibilityValue(planFirst ? "On" : "Off")
        Button { runAsGoal() } label: { Label("Goal", systemImage: "scope") }
          .buttonStyle(SubtleButtonStyle())
          .help("Work toward this in rounds until it is done (up to \(Goal.defaultMaxRounds) rounds)")
          .disabled(!app.agentOn || app.generating || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button { send() } label: { Label("Send", systemImage: "arrow.up") }
          .buttonStyle(PrimaryButtonStyle())
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(!app.agentOn || app.generating || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(16)
    .studioGlass(radius: 22)
    .padding(.horizontal, 6).padding(.bottom, 6)
  }

  private func modelMenu(_ session: Session) -> some View {
    Menu {
      ForEach(app.installed) { model in
        Button("\(model.name) · \(model.quant.rawValue)") { app.switchModel(of: session.id, to: model) }
      }
      Divider()
      Button("Install another model…") { app.route = .models }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "cube").font(.system(size: 11))
        Text(session.modelName).font(.system(size: 12, weight: .medium))
        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
      }
      .foregroundStyle(Theme.text)
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(Capsule().fill(Theme.text.opacity(0.06)))
    }
    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    .accessibilityLabel("Model")
  }

  private func send() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, app.agentOn else { return }
    draft = ""
    app.send(text, in: sessionId, plan: planFirst)
    planFirst = false
  }

  /// The word being typed, when it starts with @: the start of a file mention.
  private var mentionQuery: String? {
    guard let last = draft.split(separator: " ", omittingEmptySubsequences: false).last, last.hasPrefix("@") else { return nil }
    return String(last.dropFirst()).lowercased()
  }

  /// Up to six project files matching the mention being typed, names that start with it first.
  private func mentionSuggestions(_ session: Session) -> [String] {
    guard let query = mentionQuery, let paths = app.repoSummaries[session.projectId]?.paths else { return [] }
    let matches = paths.filter { query.isEmpty || $0.lowercased().contains(query) }
    let ranked = matches.sorted { a, b in
      let aStarts = (a as NSString).lastPathComponent.lowercased().hasPrefix(query)
      let bStarts = (b as NSString).lastPathComponent.lowercased().hasPrefix(query)
      return aStarts != bStarts ? aStarts : a.count < b.count
    }
    return Array(ranked.prefix(6))
  }

  private func insertMention(_ path: String) {
    var words = draft.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    if !words.isEmpty { words.removeLast() }
    words.append("@" + path)
    draft = words.joined(separator: " ") + " "
    composerFocused = true
  }

  /// The last turn was a plan and nothing has run since.
  private func awaitingPlanApproval(_ session: Session) -> Bool {
    guard !app.generating, session.messages.last?.role == .assistant,
          let lastUser = session.messages.last(where: { $0.role == .user }) else { return false }
    return lastUser.plan == true
  }

  static let carryOutMessage = "Carry out the plan above, step by step. Verify the change with the project's tests or build."

  private func carryOutPlan() {
    app.send(Self.carryOutMessage, in: sessionId)
  }

  private func runAsGoal() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, app.agentOn else { return }
    draft = ""
    app.startGoal(text, inSession: sessionId)
  }
}

private struct UserTurn: View {
  let message: ChatMessage
  @State private var showPrompt = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if message.content == SessionPage.carryOutMessage {
        Label("CARRY OUT THE PLAN", systemImage: "play.fill").font(.system(size: 10, weight: .semibold)).tracking(0.6)
          .foregroundStyle(Theme.accent)
      } else if let round = message.goalRound {
        // The app wrote this message, so it is folded: the round is what matters, the prompt is there if wanted.
        HStack(spacing: 6) {
          Image(systemName: "scope").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent)
          Text("GOAL  ·  ROUND \(round)").font(.system(size: 10, weight: .semibold)).tracking(0.6)
            .foregroundStyle(Theme.accent)
          Spacer()
          Button(showPrompt ? "Hide prompt" : "Show prompt") { showPrompt.toggle() }.buttonStyle(LinkButtonStyle())
        }
        if showPrompt { Text(message.content).textSelection(.enabled).lineSpacing(3).font(.system(size: 12)) }
      } else {
        HStack(spacing: 8) {
          Text("YOU").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.muted)
          if message.plan == true {
            Label("PLAN FIRST", systemImage: "list.bullet.clipboard").font(.system(size: 9.5, weight: .semibold))
              .tracking(0.6).foregroundStyle(Theme.accent)
          }
        }
        Text(message.content).textSelection(.enabled).lineSpacing(3)
      }
    }
    .font(.system(size: 14))
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.text.opacity(0.04)))
  }
}
