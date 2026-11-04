import AgentGateCore
import SwiftUI

struct ChatView: View {
  @Environment(AppModel.self) private var app
  @State private var draft = ""

  var body: some View {
    VStack(spacing: 0) {
      if app.messages.isEmpty {
        empty
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
              ForEach(app.messages) { message in
                MessageRow(message: message, thinking: app.thinking && message.id == app.messages.last?.id)
                  .id(message.id)
              }
            }
            .padding(20)
          }
          .onChange(of: app.messages.last?.content) { proxy.scrollTo(app.messages.last?.id, anchor: .bottom) }
        }
      }
      composer
    }
  }

  private var empty: some View {
    VStack(spacing: 10) {
      Image(systemName: app.active == nil ? "square.stack.3d.up" : "text.bubble").font(.system(size: 34, weight: .light))
        .foregroundStyle(.secondary)
      Text(app.active == nil ? "Choose a model to start" : "Ask \(app.active!.name) anything")
        .font(.title3.weight(.medium))
      Text(app.active == nil
           ? "Pick one from the menu at the top left. AGENTGATE installs, sets up and checks it for you."
           : app.active!.reason)
        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var composer: some View {
    HStack(alignment: .bottom, spacing: 8) {
      TextField(app.active == nil ? "Choose a model first" : "Message \(app.active!.name)", text: $draft, axis: .vertical)
        .textFieldStyle(.plain).lineLimit(1...6).onSubmit(send)
        .disabled(app.active == nil)
      Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
        .buttonStyle(.borderless)
        .disabled(app.active == nil || app.generating || draft.trimmingCharacters(in: .whitespaces).isEmpty)
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityLabel("Send")
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 10).fill(.background).stroke(.separator))
    .padding(.horizontal, 16).padding(.bottom, 12).padding(.top, 4)
  }

  private func send() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    draft = ""
    app.send(text)
  }
}

private struct MessageRow: View {
  let message: ChatMessage
  let thinking: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(message.role == .user ? "You" : "Model").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      if message.content.isEmpty {
        Text(thinking ? "Thinking…" : "…").foregroundStyle(.secondary)
      } else {
        Text(LocalizedStringKey(message.content)).textSelection(.enabled)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
