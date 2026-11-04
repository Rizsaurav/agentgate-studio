import AgentGateCore
import SwiftUI

/// Models & Providers: what this Mac can run, the recommended picks, and every model in the catalog.
struct ModelsPage: View {
  @Environment(AppModel.self) private var app
  @State private var showAll = false
  @State private var repairs: [AuditEntry] = []
  @State private var task = ""

  var body: some View {
    PageScroll {
      VStack(alignment: .leading, spacing: 32) {
        PageHeading(
          eyebrow: "Connections", title: "Models & Providers",
          detail: "Pick a model. AGENTGATE chooses the quantization for this Mac, downloads it, checks it and loads it.")
        advisor
        VStack(alignment: .leading, spacing: 12) {
          Text("System check").font(.system(size: 16, weight: .semibold))
          Card(padding: 6) {
            VStack(spacing: 0) {
              CheckRow(title: "This Mac", detail: app.profile?.summary ?? "Reading hardware…",
                       state: app.profile == nil ? nil : "Ready")
              Divider().overlay(Theme.line)
              CheckRow(title: "Model engine", detail: "llama.cpp, built into the app",
                       state: LlamaRuntime.binaryDirectory().map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("llama-server").path) } == true ? "Ready" : "Missing")
              Divider().overlay(Theme.line)
              CheckRow(title: "Memory for a model", detail: app.profile.map { ModelPlanner.gb($0.modelBudgetBytes) } ?? "…",
                       state: app.profile.map { $0.modelBudgetBytes > 0 ? "Ready" : "Too small" })
            }
          }
        }
        VStack(alignment: .leading, spacing: 12) {
          Text("RECOMMENDED FOR THIS MAC").font(.system(size: 12, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.muted)
          HStack(alignment: .top, spacing: 14) {
            ForEach(Tier.allCases, id: \.self) { tier in
              if let plan = app.tiers[tier], let model = app.catalog?.model(plan.modelId) {
                TierCard(tier: tier, plan: plan, option: app.option(model)) { app.select(model) }
              }
            }
          }
        }
        if !app.installed.isEmpty {
          VStack(alignment: .leading, spacing: 12) {
            Text("INSTALLED").font(.system(size: 12, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.muted)
            Card(padding: 6) {
              VStack(spacing: 0) {
                ForEach(app.installed) { model in
                  InstalledRow(model: model, active: app.active?.id == model.id)
                  if model.id != app.installed.last?.id { Divider().overlay(Theme.line) }
                }
              }
            }
          }
        }
        if !repairs.isEmpty {
          VStack(alignment: .leading, spacing: 12) {
            Text("REPAIR HISTORY").font(.system(size: 12, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.muted)
            Card(padding: 6) {
              VStack(spacing: 0) {
                ForEach(Array(repairs.suffix(20).reversed().enumerated()), id: \.offset) { index, entry in
                  RepairRow(entry: entry)
                  if index < min(repairs.count, 20) - 1 { Divider().overlay(Theme.line) }
                }
              }
            }
          }
        }
        VStack(alignment: .leading, spacing: 12) {
          Button { withAnimation { showAll.toggle() } } label: {
            HStack {
              Text("ALL OPEN MODELS").font(.system(size: 12, weight: .semibold)).tracking(0.6)
              Image(systemName: showAll ? "chevron.up" : "chevron.down").font(.system(size: 10))
            }
            .foregroundStyle(Theme.muted)
          }
          .buttonStyle(.plain)
          if showAll {
            Card(padding: 6) {
              VStack(spacing: 0) {
                ForEach(app.allOptions) { option in
                  CatalogRow(option: option) { app.select(option.model) }
                  if option.id != app.allOptions.last?.id { Divider().overlay(Theme.line) }
                }
              }
            }
          }
        }
      }
      .frame(maxWidth: 820, alignment: .leading)
    }
    .onAppear { repairs = AuditLog().entries() }
  }

  /// Describe the work; get up to three models for this Mac, each one click away.
  private var advisor: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        TextField("What will you use it for?", text: $task).field().onSubmit { app.suggestModels(for: task) }
          .accessibilityLabel("What will you use it for?")
        Button(app.advising ? "Thinking…" : "Suggest") { app.suggestModels(for: task) }
          .buttonStyle(PrimaryButtonStyle()).disabled(task.trimmingCharacters(in: .whitespaces).isEmpty || app.advising)
      }
      if let note = app.advisorNote { Text(note).font(.system(size: 12)).foregroundStyle(Theme.muted) }
      if !app.suggestions.isEmpty {
        HStack(alignment: .top, spacing: 14) {
          ForEach(Array(app.suggestions.enumerated()), id: \.element.id) { index, pick in
            Card(padding: 16) {
              VStack(alignment: .leading, spacing: 8) {
                if index == 0 { StatusPill(text: "Best match", tone: .ok) }
                Text(pick.model.name).font(.system(size: 14, weight: .semibold))
                ForEach(pick.reasons, id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(Theme.muted) }
                Button(pick.installed ? (app.active?.id == pick.model.id ? "Loaded" : "Use") : "Install") { app.select(pick.model) }
                  .buttonStyle(PrimaryButtonStyle()).padding(.top, 4)
                  .disabled(app.active?.id == pick.model.id || app.installing != nil)
              }
            }
          }
        }
      }
    }
  }
}

/// One audited repair step: what, why, and what happened.
private struct RepairRow: View {
  let entry: AuditEntry

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("\(entry.modelId) · \(entry.operation)").font(.system(size: 13, weight: .medium))
        Text(entry.reason).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(2)
      }
      Spacer(minLength: 8)
      Text(entry.outcome.rawValue).font(.system(size: 12)).foregroundStyle(Theme.muted)
      Text(entry.date, style: .relative).font(.system(size: 12)).foregroundStyle(Theme.muted)
    }
    .padding(10)
    .accessibilityElement(children: .combine)
  }
}

private struct CheckRow: View {
  let title: String
  let detail: String
  let state: String?

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.system(size: 13, weight: .medium))
        Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
      }
      Spacer()
      if let state { StatusPill(text: state, tone: state == "Ready" ? .ok : .bad) }
    }
    .padding(.horizontal, 16).padding(.vertical, 12)
  }
}

private struct TierCard: View {
  @Environment(AppModel.self) private var app
  let tier: Tier
  let plan: ModelPlan
  let option: ModelOption
  let install: () -> Void

  var body: some View {
    Card(padding: 18) {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text(tier.label).font(.system(size: 15, weight: .semibold))
          Spacer()
          badge
        }
        Text(option.model.name).font(.system(size: 13))
        Text("\(plan.quant.rawValue) · \(plan.context / 1024)K context · \(ModelPlanner.gb(plan.downloadBytes))")
          .font(.system(size: 12)).foregroundStyle(Theme.muted)
        Button(action: install) { Text(buttonTitle) }
          .buttonStyle(PrimaryButtonStyle()).padding(.top, 4)
          .disabled(app.active?.id == option.model.id || app.installing != nil)
          .help(plan.reason)
      }
    }
  }

  private var buttonTitle: String {
    switch option.state {
    case .ready, .chatOnly: app.active?.id == option.model.id ? "Loaded" : "Load"
    default: "Install"
    }
  }

  @ViewBuilder private var badge: some View {
    switch option.state {
    case .ready: StatusPill(text: "Installed", tone: .ok)
    case .chatOnly: StatusPill(text: "Chat only", tone: .pending)
    default: EmptyView()
    }
  }
}

private struct InstalledRow: View {
  @Environment(AppModel.self) private var app
  let model: InstalledModel
  let active: Bool
  @State private var confirm = false

  var body: some View {
    HStack(spacing: 14) {
      IconTile(symbol: "cube", size: 36)
      VStack(alignment: .leading, spacing: 3) {
        Text(model.name).font(.system(size: 13, weight: .medium))
        Text("\(model.quant.rawValue) · \(model.config.context / 1024)K context · \(ModelPlanner.gb(model.bytes))")
          .font(.system(size: 12)).foregroundStyle(Theme.muted)
      }
      Spacer()
      if active { StatusPill(text: "Loaded", tone: .ok) }
      else if model.readiness == .chatOnly { StatusPill(text: "Chat only", tone: .pending) }
      Button("Remove") { confirm = true }.buttonStyle(SubtleButtonStyle())
        .accessibilityLabel("Remove \(model.name)")
        .confirmationDialog("Remove \(model.name)?", isPresented: $confirm) {
          Button("Remove and free \(ModelPlanner.gb(model.bytes))", role: .destructive) { app.remove(model) }
        }
    }
    .padding(.horizontal, 14).padding(.vertical, 10)
  }
}

private struct CatalogRow: View {
  let option: ModelOption
  let install: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 3) {
        Text(option.model.name).font(.system(size: 13, weight: .medium))
        Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
      }
      Spacer()
      switch option.state {
      case .ready: StatusPill(text: "Installed", tone: .ok)
      case .chatOnly: StatusPill(text: "Chat only", tone: .pending)
      case .notInstalled: Button("Install", action: install).buttonStyle(SubtleButtonStyle())
      case .incompatible: StatusPill(text: "Too large", tone: .neutral)
      }
    }
    .padding(.horizontal, 14).padding(.vertical, 10)
    .help(help)
  }

  private var detail: String {
    let tools = option.model.toolCalling ? "tools" : "chat only"
    if let plan = option.plan {
      return "\(option.model.publisher) · \(plan.quant.rawValue) · \(ModelPlanner.gb(plan.downloadBytes)) · \(tools)"
    }
    if case .incompatible(let reason) = option.state { return reason }
    return "\(option.model.publisher) · \(tools)"
  }

  private var help: String {
    if case .incompatible(let reason) = option.state { return reason }
    return option.plan?.reason ?? ""
  }
}
