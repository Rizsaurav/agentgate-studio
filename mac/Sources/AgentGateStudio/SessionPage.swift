import AgentGateCore
import SwiftUI

struct SessionPage: View {
  @Environment(AppModel.self) private var app
  let sessionId: UUID
  @State private var draft = ""
  @FocusState private var composerFocused: Bool
  @AppStorage("terminalOpen") private var terminalOpen = false

  var body: some View {
    if let session = app.session(sessionId), let project = app.project(session.projectId) {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Button { app.route = .project(project.id) } label: { Text("← \(project.name)").font(.system(size: 13)) }
            .buttonStyle(.plain).foregroundStyle(Theme.muted)
          Spacer()
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
        VStack(spacing: 12) {
          IconTile(symbol: "sparkle", size: 56)
          Text("What are we working on?").font(.system(size: 15, weight: .semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
              ForEach(session.messages) { message in
                Turn(message: message, thinking: app.thinking && message.id == session.messages.last?.id).id(message.id)
              }
            }
            .padding(22)
          }
          .onChange(of: session.messages.last?.content) { proxy.scrollTo(session.messages.last?.id, anchor: .bottom) }
        }
      }
      composer(session)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)

  }

  private func composer(_ session: Session) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      if !app.agentOn {
        HStack(spacing: 10) {
          Image(systemName: "key").foregroundStyle(Theme.accent)
          Text("Add an API key to turn on the agent, then start working.").font(.system(size: 13))
          Spacer()
          Button("Add a key") { app.route = .profile }.buttonStyle(PrimaryButtonStyle())
        }
      }
      TextField("Task", text: $draft, prompt: Text(""), axis: .vertical)
        .inputHint("Ask anything about your project…", when: draft.isEmpty)
        .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(3...8)
        .accessibilityLabel("Task")
        .focused($composerFocused)
        .onAppear { composerFocused = true }
        .onSubmit { send() }
      HStack {
        modelMenu(session)
        Text(modelState(session)).font(.system(size: 11)).foregroundStyle(Theme.muted)
        Spacer()
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
    app.send(text, in: sessionId)
  }
}

private struct Turn: View {
  let message: ChatMessage
  let thinking: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(message.role == .user ? "YOU" : "MODEL").font(.system(size: 10, weight: .semibold)).tracking(0.6)
        .foregroundStyle(message.role == .user ? Theme.muted : Theme.accent)
      if message.content.isEmpty {
        Text(thinking ? "Thinking…" : "Generating…").foregroundStyle(Theme.muted)
      } else {
        Text(LocalizedStringKey(message.content)).textSelection(.enabled).lineSpacing(3)
      }
    }
    .font(.system(size: 14))
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
