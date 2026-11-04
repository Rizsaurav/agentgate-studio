import AgentGateCore
import SwiftUI

/// The repair agent: whether it is on, what it does, and what it has done.
struct AgentPanel: View {
  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss
  @State private var key = ""
  @State private var history: [AuditEntry] = []

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Repair agent").font(.system(size: 17, weight: .semibold))
        Spacer()
        Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      HStack(spacing: 8) {
        Circle().fill(app.agentOn ? Theme.accent : Theme.muted).frame(width: 8, height: 8)
        Text(app.agentOn ? "On · \(OpenRouterAssistant.model) via OpenRouter" : "Off · installs use fixed repairs only")
          .font(.system(size: 13))
      }
      Text("When a step fails, the agent looks around (disk, memory, network, the models folder), chooses a fix, and tries again. You approve anything that deletes files, lowers quality, or downloads over 1 GB. Every look and every fix is logged below.")
        .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
      if app.agentOn {
        Button("Disconnect") { app.disconnectAgent() }.controlSize(.small)
      } else {
        HStack {
          SecureField("OpenRouter key", text: $key).field().accessibilityLabel("OpenRouter key")
          Button("Connect") { if app.connectAgent(key: key) { key = "" } }
            .buttonStyle(PrimaryButtonStyle()).disabled(key.isEmpty)
        }
      }
      Divider().overlay(Theme.line)
      Text("History").font(.system(size: 13, weight: .semibold))
      if history.isEmpty {
        Text("Nothing yet. It acts only when an install step fails.").font(.system(size: 12)).foregroundStyle(Theme.muted)
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
    .frame(minWidth: 520, idealWidth: 580, minHeight: 360, idealHeight: 440)
    .background(Theme.bg)
    .preferredColorScheme(.dark)
    .onAppear { history = AuditLog().entries() }
  }
}
