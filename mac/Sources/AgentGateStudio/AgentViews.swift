import AgentGateCore
import SwiftUI

/// The live line for the agent at the bottom of the window: what it is doing right now and for how
/// long, with Stop, or the question waiting for the user. The full detail is in the conversation.
struct AgentStrip: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    if app.generating || app.pendingPermission != nil {
      VStack(spacing: 0) {
        Divider().overlay(Theme.line)
        HStack(spacing: 12) {
          if app.pendingPermission != nil {
            Image(systemName: "hand.raised.fill").foregroundStyle(Theme.warning).font(.system(size: 12))
          } else {
            ProgressView().controlSize(.small)
          }
          Text(summary).font(.system(size: 13, design: running == nil ? .default : .monospaced)).lineLimit(1)
            .truncationMode(.middle)
          if let started = running?.started ?? app.turnStarted, app.pendingPermission == nil {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
              Text(seconds(context.date.timeIntervalSince(started))).monospacedDigit()
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
          }
          Spacer(minLength: 8)
          if app.pendingPermission != nil {
            Button("Deny") { app.answerPermission(allow: false) }.controlSize(.small)
            Button("Allow once") { app.answerPermission(allow: true) }
              .controlSize(.small).buttonStyle(.borderedProminent)
          } else {
            Button("Stop") { app.stopAgent() }.controlSize(.small).keyboardShortcut(".", modifiers: .command)
              .help("Stop the agent (⌘.)")
          }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
      }
      .background(.bar)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Agent activity")
    }
  }

  private var running: AgentStep? { app.transcript.running }

  private var summary: String {
    if let permission = app.pendingPermission { return "Waiting for you: allow \(permission.tool)?  \(permission.detail)" }
    if let running, running.text.isEmpty { return "Preparing a \(running.tool == "bash" ? "command" : running.tool)…" }
    if let running {
      let what = running.tool == "bash" ? "$ \(running.text)" : "\(running.tool) \(running.text)"
      return what.replacingOccurrences(of: "\n", with: " ")
    }
    let done = app.transcript.steps.filter { $0.kind == .tool }.count
    return done == 0 ? "Thinking…" : "Thinking… · \(plural(done, "step")) so far"
  }
}
