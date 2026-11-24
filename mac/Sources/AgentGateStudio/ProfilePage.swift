import AgentGateCore
import SwiftUI

/// Keys, the supervising agent, and shortcuts. Keys are checked with their provider and kept in the Keychain.
struct ProfilePage: View {
  @Environment(AppModel.self) private var app
  @State private var pasted = ""
  @State private var choice: String?
  @State private var message: String?
  @State private var saving = false

  var body: some View {
    PageScroll {
      VStack(alignment: .leading, spacing: 30) {
        Text("Profile").font(.system(size: 30, weight: .bold)).tracking(-0.6)
        agent
        keys
        TokenUsageSection()
        CloudLimitsSection()
        shortcuts
      }
      .frame(maxWidth: 680, alignment: .leading)
    }
  }

  private var agent: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Supervising agent").font(.system(size: 16, weight: .semibold))
      Card(padding: 16) {
        HStack(spacing: 12) {
          Circle().fill(app.agentOn ? Theme.accent : Theme.muted).frame(width: 9, height: 9)
          VStack(alignment: .leading, spacing: 3) {
            Text(app.activeAgent.name).font(.system(size: 14, weight: .medium))
            Text(app.agentOn ? "On · watches installs and fixes failures" : "Off · add an \(app.activeAgent.isBuiltIn ? "OpenRouter " : "")key below to turn it on")
              .font(.system(size: 12)).foregroundStyle(Theme.muted)
          }
          Spacer()
          Button("Change") { app.agentPanelOpen = true }.controlSize(.small)
        }
      }
    }
  }

  private var keys: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("API keys").font(.system(size: 16, weight: .semibold))
      HStack(spacing: 10) {
        SecureField("Paste a key from any provider", text: $pasted).field().accessibilityLabel("API key")
          .onChange(of: pasted) { choice = Providers.candidates(for: pasted).first?.id; message = nil }
        Button(saving ? "Checking…" : "Save") { save() }
          .buttonStyle(PrimaryButtonStyle()).disabled(target == nil || saving)
      }
      let candidates = Providers.candidates(for: pasted)
      if !pasted.isEmpty {
        if candidates.count > 1 {
          Picker("Provider", selection: $choice) {
            ForEach(candidates) { Text($0.name).tag(Optional($0.id)) }
          }
          .pickerStyle(.segmented).frame(width: 280)
        } else if let only = candidates.first {
          Text("Looks like an \(only.name) key.").font(.system(size: 12)).foregroundStyle(Theme.muted)
        } else {
          Picker("Provider", selection: $choice) {
            Text("Choose provider").tag(String?.none)
            ForEach(Providers.all) { Text($0.name).tag(Optional($0.id)) }
          }
          .frame(width: 280)
        }
      }
      if let message { Text(message).font(.system(size: 12)).foregroundStyle(Theme.muted) }
      Card(padding: 6) {
        VStack(spacing: 0) {
          ForEach(Providers.all) { provider in
            HStack(spacing: 12) {
              VStack(alignment: .leading, spacing: 2) {
                Text(provider.name).font(.system(size: 13, weight: .medium))
                if provider.id == Providers.openRouter.id {
                  Text("Powers the built-in agent").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
              }
              Spacer()
              if app.providerKeys.contains(provider.id) {
                StatusPill(text: "Key saved", tone: .ok)
                Button("Remove") { app.removeProviderKey(provider) }.controlSize(.small)
              } else if let url = URL(string: provider.keysPage) {
                Link("Get a key", destination: url).font(.system(size: 12)).foregroundStyle(Theme.accent)
              }
            }
            .padding(10)
            if provider.id != Providers.all.last?.id { Divider().overlay(Theme.line) }
          }
        }
      }
      Text("Each key is checked with its provider before it is saved, stored in the macOS Keychain, and never shown again.")
        .font(.system(size: 12)).foregroundStyle(Theme.muted)
    }
  }

  private var shortcuts: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Shortcuts").font(.system(size: 16, weight: .semibold))
      Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
        ForEach([("Find a project or view", "⌘ K"), ("Workspace", "⌘ 1"), ("Security & Verification", "⌘ 2"),
                 ("Models", "⌘ 3"), ("Send a task", "Return")], id: \.0) { row in
          GridRow {
            Text(row.0).foregroundStyle(Theme.muted)
            Text(row.1).font(.system(size: 11, weight: .medium))
          }
        }
      }
      .font(.system(size: 12))
    }
  }

  private var target: Provider? {
    guard !pasted.isEmpty, let choice else { return nil }
    return Providers.all.first { $0.id == choice }
  }

  private func save() {
    guard let provider = target else { return }
    saving = true
    Task {
      let result = await app.saveProviderKey(provider, key: pasted)
      saving = false
      message = result.message
      if result.saved { pasted = ""; choice = nil }
    }
  }
}

/// Tokens each model has processed, as its engine or provider reported them. Local and cloud in separate rows.
private struct TokenUsageSection: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Token use").font(.system(size: 16, weight: .semibold))
      if app.tokenCounts.isEmpty {
        Text("Nothing counted yet. Counts appear after a chat, from what the engine reports.")
          .font(.system(size: 12)).foregroundStyle(Theme.muted)
      } else {
        Card(padding: 12) {
          Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow {
              ForEach(["Model", "Prompt", "Generated", "Total", "Last used", ""], id: \.self) {
                Text($0).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
              }
            }
            ForEach(app.tokenCounts) { count in
              GridRow {
                VStack(alignment: .leading, spacing: 2) {
                  Text(count.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                  Text(count.location == .local ? "Local" : "Cloud").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Text(count.prompt.formatted()).monospacedDigit()
                Text(count.generated.formatted()).monospacedDigit()
                Text(count.total.formatted()).monospacedDigit().fontWeight(.medium)
                Text(count.lastUsed, style: .relative).foregroundStyle(Theme.muted)
                Button("Reset") { app.resetTokens(count) }.controlSize(.small)
                  .accessibilityLabel("Reset token count for \(count.name)")
              }
              .font(.system(size: 12))
              if count.unreported > 0 {
                GridRow {
                  Text("\(count.unreported) \(count.unreported == 1 ? "reply" : "replies") came without a count and were not added.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).gridCellColumns(6)
                }
              }
            }
          }
        }
        HStack(spacing: 18) {
          ForEach(ModelLocation.allCases, id: \.self) { location in
            let total = app.tokenCounts.filter { $0.location == location }.reduce(0) { $0 + $1.total }
            Text("All-time \(location == .local ? "local" : "cloud"): \(total.formatted()) tokens")
          }
        }
        .font(.system(size: 12)).foregroundStyle(Theme.muted)
      }
    }
    .onAppear { app.loadTokenCounts() }
  }
}

/// Spending limits for cloud models, and what has been spent today and this session.
private struct CloudLimitsSection: View {
  @Environment(AppModel.self) private var app
  @State private var turn = ""
  @State private var session = ""
  @State private var day = ""
  @State private var saved = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Cloud spending limits").font(.system(size: 16, weight: .semibold))
      Text("Checked before every cloud request. Uses the cost the provider reports. Leave a field empty for no limit.")
        .font(.system(size: 12)).foregroundStyle(Theme.muted)
      Card(padding: 14) {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 14) {
            field("Per turn", $turn)
            field("Per session", $session)
            field("Per day", $day)
            Button(saved ? "Saved" : "Save") { save() }.buttonStyle(PrimaryButtonStyle())
          }
          Divider()
          HStack(spacing: 18) {
            Text("Today: \(Spend.format(app.spentToday))\(app.cloudLimits.perDay.map { " of \(Spend.format($0))" } ?? "")")
              .fontWeight(.medium)
            Text("This session: \(Spend.format(app.costGuard.spentThisSession))").foregroundStyle(Theme.muted)
            if app.costGuard.unpricedReplies > 0 {
              Text("\(app.costGuard.unpricedReplies) without a reported cost").foregroundStyle(Theme.muted)
            }
          }
          .font(.system(size: 12))
          if let limit = app.cloudLimits.perDay, app.spentToday >= limit {
            Text("Today's limit is reached. Nothing more is sent to cloud models until tomorrow.")
              .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.danger)
          }
        }
      }
    }
    .onAppear {
      app.refreshSpend()
      turn = text(app.cloudLimits.perTurn)
      session = text(app.cloudLimits.perSession)
      day = text(app.cloudLimits.perDay)
    }
  }

  private func field(_ label: String, _ value: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
      HStack(spacing: 2) {
        Text("$").foregroundStyle(Theme.muted)
        TextField("none", text: value).field().frame(width: 80).accessibilityLabel("\(label) limit in dollars")
          .onChange(of: value.wrappedValue) { saved = false }
      }
    }
  }

  private func text(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "" }

  private func save() {
    func number(_ text: String) -> Double? { Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")) }
    app.setCloudLimits(CloudLimits(perTurn: number(turn), perSession: number(session), perDay: number(day)))
    turn = text(app.cloudLimits.perTurn)
    session = text(app.cloudLimits.perSession)
    day = text(app.cloudLimits.perDay)
    saved = true
  }
}
