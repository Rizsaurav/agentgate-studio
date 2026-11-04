import AgentGateCore
import SwiftUI

struct SessionPage: View {
  @Environment(AppModel.self) private var app
  let sessionId: UUID
  @State private var draft = ""

  var body: some View {
    if let session = app.session(sessionId), let project = app.project(session.projectId) {
      VStack(alignment: .leading, spacing: 26) {
        Button { app.route = .project(project.id) } label: { Text("← \(project.name)").font(.system(size: 13)) }
          .buttonStyle(.plain).foregroundStyle(Theme.muted)
        PageHeading(eyebrow: project.name, title: "Agent session", detail: "\(session.modelName) · local · Saved locally")
        HStack(alignment: .top, spacing: 24) {
          conversation(session)
          VStack(spacing: 16) {
            SideCard(title: "Selected model") {
              Label(session.modelName, systemImage: "cube").font(.system(size: 14, weight: .medium))
              Text(modelState(session)).font(.system(size: 12)).foregroundStyle(Theme.muted)
              Button("Start a session with another model →") { app.route = .project(project.id) }
                .buttonStyle(LinkButtonStyle())
            }
            SideCard(title: "Task activity") {
              let tasks = session.messages.filter { $0.role == .user }
              if tasks.isEmpty {
                Text("No tasks have run in this session.").font(.system(size: 12)).foregroundStyle(Theme.muted)
              } else {
                ForEach(tasks.suffix(5).reversed()) { task in
                  Label(task.content, systemImage: "checkmark").font(.system(size: 12)).lineLimit(1)
                }
              }
            }
            SideCard(title: "Protection") {
              Text("The model runs on this Mac and answers only to this app, behind a per-launch key. Security checks arrive with the bundled harness.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
              Button("Security & Verification →") { app.route = .security }.buttonStyle(LinkButtonStyle())
            }
          }
          .frame(width: 240)
        }
      }
      .padding(.horizontal, 42).padding(.top, 40).padding(.bottom, 24)
      .frame(maxWidth: 1100, maxHeight: .infinity, alignment: .topLeading)
      .frame(maxWidth: .infinity, alignment: .leading)
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
          Text("What would you like to work on?").font(.system(size: 15, weight: .semibold))
          Text("Your project stays on this Mac. The model answers from the engine built into the app.")
            .font(.system(size: 13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: 340)
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
    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
  }

  private func composer(_ session: Session) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      TextField("Ask anything about your project…", text: $draft, axis: .vertical)
        .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(3...8)
        .accessibilityLabel("Task")
      HStack {
        Text("Runs on this Mac · ⌘ Return").font(.system(size: 11)).foregroundStyle(Theme.muted)
        Spacer()
        Button { send() } label: { Label("Run task", systemImage: "paperplane") }
          .buttonStyle(PrimaryButtonStyle())
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(app.generating || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(16)
    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raised.opacity(0.6)))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    .padding(18)
  }

  private func send() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
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

private struct SideCard<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content
  var body: some View {
    Card(padding: 18) {
      VStack(alignment: .leading, spacing: 12) {
        Text(title).font(.system(size: 13, weight: .medium))
        content
      }
    }
  }
}
