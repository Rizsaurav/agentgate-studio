import AgentGateCore
import SwiftUI

/// The supervising agent: pick which one, add your own, and see what it has done.
struct AgentPanel: View {
  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss
  @State private var key = ""
  @State private var history: [AuditEntry] = []
  @State private var adding = false
  @State private var name = ""
  @State private var address = "https://"
  @State private var model = ""
  @State private var newKey = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Supervising agent").font(.system(size: 17, weight: .semibold))
        Spacer()
        Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      Text("Watches every install, looks into failures, searches the web, and chooses the fix. You approve anything that deletes files, lowers quality, switches the download source, or downloads over 1 GB.")
        .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
      VStack(spacing: 0) {
        ForEach(app.agents) { agent in
          HStack(spacing: 10) {
            Button { app.selectAgent(agent.id) } label: {
              Image(systemName: app.activeAgentID == agent.id ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(app.activeAgentID == agent.id ? Theme.accent : Theme.muted)
            }
            .buttonStyle(.plain).accessibilityLabel("Use \(agent.name)")
            VStack(alignment: .leading, spacing: 2) {
              Text(agent.name).font(.system(size: 13, weight: .medium))
              Text(agent.model).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            Spacer()
            StatusPill(text: app.agentKeys.contains(agent.id) ? "Key saved" : "No key", tone: app.agentKeys.contains(agent.id) ? .ok : .pending)
            if agent.isBuiltIn {
              if app.agentKeys.contains(agent.id) { Button("Remove key") { app.disconnectAgent() }.controlSize(.small) }
            } else {
              Button("Remove") { app.removeAgent(agent.id) }.controlSize(.small)
            }
          }
          .padding(10)
          if agent.id != app.agents.last?.id { Divider().overlay(Theme.line) }
        }
      }
      .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
      if !app.agentOn && app.activeAgent.isBuiltIn {
        HStack {
          SecureField("OpenRouter key", text: $key).field().accessibilityLabel("OpenRouter key")
          Button("Save key") { if app.connectAgent(key: key) { key = "" } }
            .buttonStyle(PrimaryButtonStyle()).disabled(key.isEmpty)
        }
      }
      if adding {
        VStack(alignment: .leading, spacing: 8) {
          TextField("Name", text: $name).field().accessibilityLabel("Agent name")
          TextField("Provider address, e.g. https://api.openai.com/v1", text: $address).field().accessibilityLabel("Provider address")
          TextField("Model, e.g. gpt-4.1-mini", text: $model).field().accessibilityLabel("Model")
          SecureField("Key", text: $newKey).field().accessibilityLabel("Key")
          HStack {
            Button("Add agent") {
              if app.addAgent(name: name, address: address, model: model, key: newKey) {
                adding = false; name = ""; address = "https://"; model = ""; newKey = ""
              }
            }
            .buttonStyle(PrimaryButtonStyle()).disabled(name.isEmpty || model.isEmpty || newKey.isEmpty)
            Button("Cancel") { adding = false }.buttonStyle(.plain).foregroundStyle(Theme.muted)
          }
        }
      } else {
        Button("Add your own agent…") { adding = true }.buttonStyle(.plain).foregroundStyle(Theme.accent).font(.system(size: 13))
      }
      Divider().overlay(Theme.line)
      Text("History").font(.system(size: 13, weight: .semibold))
      if history.isEmpty {
        Text("Nothing yet. It acts when an install step fails.").font(.system(size: 12)).foregroundStyle(Theme.muted)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(Array(history.suffix(30).reversed().enumerated()), id: \.offset) { _, entry in
            VStack(alignment: .leading, spacing: 2) {
              HStack {
                Text("\(entry.modelId) · \(entry.operation)").font(.system(size: 12, weight: .medium))
                Spacer()
                Text(entry.outcome.rawValue).font(.system(size: 11)).foregroundStyle(Theme.muted)
              }
              Text(entry.reason).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(3)
            }
          }
        }
      }
    }
    .padding(22)
    .frame(minWidth: 540, idealWidth: 600, minHeight: 420, idealHeight: 520)
    .background(Theme.bg)
    .preferredColorScheme(.dark)
    .onAppear { history = AuditLog().entries() }
  }
}
