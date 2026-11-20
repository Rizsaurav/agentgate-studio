import AgentGateCore
import SwiftUI

/// The live line for the agent: what it is doing right now. Click it to see everything it ran.
struct AgentStrip: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    if app.generating || app.pendingPermission != nil || !app.activity.isEmpty {
      VStack(spacing: 0) {
        Divider().overlay(Theme.line)
        HStack(spacing: 12) {
          Button { app.activityOpen = true } label: {
            HStack(spacing: 10) {
              Circle().fill(app.generating ? Theme.accent : Theme.muted).frame(width: 8, height: 8)
              Text(summary).font(.system(size: 13, design: current == nil ? .default : .monospaced)).lineLimit(1)
              Image(systemName: "chevron.up").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help("Show everything the agent ran")
          Spacer(minLength: 8)
          if app.pendingPermission != nil {
            Button("Deny") { app.answerPermission(allow: false) }.controlSize(.small)
            Button("Allow once") { app.answerPermission(allow: true) }
              .controlSize(.small).buttonStyle(.borderedProminent)
          } else if app.generating {
            Button("Stop") { app.stopAgent() }.controlSize(.small)
          }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
      }
      .background(.bar)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Agent activity")
    }
  }

  /// The command being asked about or run, if any.
  private var current: String? {
    if let permission = app.pendingPermission { return permission.detail }
    return app.activity.last { $0.status == "running" || $0.status == "pending" }?.detail
  }

  private var summary: String {
    if let permission = app.pendingPermission { return "Allow \(permission.tool)?  \(permission.detail)" }
    if let current { return current }
    if app.generating { return "Thinking…" }
    return "Done · \(plural(app.activity.count, "step"))"
  }
}

/// Everything the agent ran in this turn, as written by the model, with the output.
struct ActivitySheet: View {
  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("What the agent did").font(.system(size: 17, weight: .semibold))
        Spacer()
        Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      if let permission = app.pendingPermission {
        row(tool: permission.tool, detail: permission.detail, status: "waiting for you", output: "")
      }
      if app.activity.isEmpty && app.pendingPermission == nil {
        Text("Nothing has run yet.").foregroundStyle(Theme.muted)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(app.activity.reversed()) { item in
            row(tool: item.tool, detail: item.detail, status: item.status, output: item.output)
          }
        }
      }
    }
    .padding(22)
    .frame(minWidth: 560, idealWidth: 640, minHeight: 360, idealHeight: 460)
    .background(Theme.bg)
    .preferredColorScheme(.dark)
  }

  private func row(tool: String, detail: String, status: String, output: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(tool).font(.system(size: 11, weight: .semibold)).tracking(0.5).foregroundStyle(Theme.accent)
        Spacer()
        Text(status).font(.system(size: 11)).foregroundStyle(Theme.muted)
      }
      Text(detail).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
      if !output.isEmpty {
        Text(String(output.prefix(2000))).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
          .textSelection(.enabled).lineLimit(14)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
  }
}
