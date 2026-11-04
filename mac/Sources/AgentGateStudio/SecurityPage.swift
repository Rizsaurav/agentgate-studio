import AgentGateCore
import SwiftUI

/// What the rules checked, and proof that the rules still work.
struct SecurityPage: View {
  @Environment(AppModel.self) private var app
  @State private var results: [(title: String, passed: Bool)]?
  @State private var showCases = false

  var body: some View {
    PageScroll {
      VStack(alignment: .leading, spacing: 28) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Security").font(.system(size: 30, weight: .bold)).tracking(-0.6)
          Text("These checks reduce risk. They do not guarantee protection from every attack.")
            .font(.system(size: 13)).foregroundStyle(Theme.muted)
        }
        HStack(spacing: 22) {
          status("Model engine", "Local only", .ok)
          status("Commands and edits", "Ask first", .ok)
          status("Scanner", "Not installed", .neutral)
        }
        rules
        activity
      }
      .frame(maxWidth: 760, alignment: .leading)
    }
    .onAppear { app.loadSecurityEntries() }
  }

  private func status(_ title: String, _ value: String, _ tone: StatusPill.Tone) -> some View {
    HStack(spacing: 8) {
      Text(title).font(.system(size: 13))
      StatusPill(text: value, tone: tone)
    }
  }

  private var rules: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Rule checks").font(.system(size: 16, weight: .semibold))
        Spacer()
        if let results {
          let passed = results.filter(\.passed).count
          Text("\(passed) of \(results.count) pass").font(.system(size: 13))
            .foregroundStyle(passed == results.count ? Theme.accent : Theme.danger)
        }
        Button("Run checks") { run() }.buttonStyle(PrimaryButtonStyle())
      }
      Text("Each case is a command or edit the rules must allow or block.")
        .font(.system(size: 12)).foregroundStyle(Theme.muted)
      if let results {
        Button { withAnimation { showCases.toggle() } } label: {
          Label(showCases ? "Hide cases" : "Show cases", systemImage: showCases ? "chevron.up" : "chevron.down")
            .font(.system(size: 12))
        }
        .buttonStyle(.plain).foregroundStyle(Theme.muted)
        if showCases {
          Card(padding: 8) {
            VStack(spacing: 0) {
              ForEach(Array(results.enumerated()), id: \.offset) { _, item in
                HStack {
                  Image(systemName: item.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(item.passed ? Theme.accent : Theme.danger)
                  Text(item.title).font(.system(size: 13))
                  Spacer()
                }
                .padding(.vertical, 5).padding(.horizontal, 8)
              }
            }
          }
        }
      }
    }
  }

  private var activity: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Agent activity").font(.system(size: 16, weight: .semibold))
        Spacer()
        let blocked = app.securityEntries.filter { $0.outcome == .blocked || $0.outcome == .stopped }.count
        Text("\(plural(app.securityEntries.count, "request")) · \(blocked) blocked")
          .font(.system(size: 12)).foregroundStyle(Theme.muted)
      }
      if app.securityEntries.isEmpty {
        Text("Nothing yet. Commands and edits the agent asks for appear here.")
          .font(.system(size: 13)).foregroundStyle(Theme.muted)
          .padding(24).frame(maxWidth: .infinity, alignment: .leading)
          .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4])))
      } else {
        Card(padding: 6) {
          VStack(spacing: 0) {
            ForEach(Array(app.securityEntries.suffix(50).reversed().enumerated()), id: \.element.id) { index, entry in
              EntryRow(entry: entry)
              if index < min(app.securityEntries.count, 50) - 1 { Divider().overlay(Theme.line) }
            }
          }
        }
      }
    }
  }

  private func run() {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agentgate-rule-check")
    results = ToolPolicy.selfTest(folder: folder)
  }
}

private struct EntryRow: View {
  let entry: SecurityEntry

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(entry.detail).font(.system(size: 13, design: .monospaced)).lineLimit(2)
        Text("\(entry.tool) · \(entry.project)" + (entry.rule.isEmpty ? "" : " · \(entry.rule)"))
          .font(.system(size: 11)).foregroundStyle(Theme.muted)
      }
      Spacer(minLength: 8)
      Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(blocked ? Theme.danger : Theme.muted)
      Text(entry.date, style: .relative).font(.system(size: 11)).foregroundStyle(Theme.muted)
    }
    .padding(10)
    .accessibilityElement(children: .combine)
  }

  private var blocked: Bool { entry.outcome == .blocked || entry.outcome == .stopped }

  private var label: String {
    switch entry.outcome {
    case .allowed: "allowed"
    case .blocked: "blocked"
    case .deniedByUser: "you denied"
    case .stopped: "stopped"
    }
  }
}
