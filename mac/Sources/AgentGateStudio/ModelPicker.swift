import AgentGateCore
import SwiftUI

/// The model selector: tiers chosen for this Mac, then every model in the catalog.
struct ModelPicker: View {
  @Environment(AppModel.self) private var app
  @State private var open = false

  var body: some View {
    Button { open.toggle() } label: {
      HStack(spacing: 6) {
        Text(app.active?.name ?? "Choose a model").fontWeight(.semibold)
        if let active = app.active { Text(active.quant.rawValue).foregroundStyle(.secondary) }
        Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
      }
    }
    .popover(isPresented: $open, arrowEdge: .bottom) {
      ModelList { open = false }.environment(app)
    }
    .help("Choose a model. It is installed and set up for you.")
  }
}

private struct ModelList: View {
  @Environment(AppModel.self) private var app
  let close: () -> Void
  @State private var showAll = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 2) {
        header("Recommended for this Mac")
        ForEach(Tier.allCases, id: \.self) { tier in
          if let plan = app.tiers[tier], let model = app.catalog?.model(plan.modelId) {
            Row(title: tier.label, subtitle: "\(model.name) · \(plan.quant.rawValue)", option: app.option(model),
                active: app.active?.id == model.id) { choose(model) }
          }
        }
        Divider().padding(.vertical, 6)
        Button { withAnimation { showAll.toggle() } } label: {
          HStack {
            Text("All open models").font(.callout.weight(.medium))
            Spacer()
            Image(systemName: showAll ? "chevron.up" : "chevron.down").font(.caption)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 4)
        if showAll {
          ForEach(app.allOptions) { option in
            Row(title: option.model.name, subtitle: option.model.publisher, option: option,
                active: app.active?.id == option.id) { choose(option.model) }
          }
        }
        if !app.installed.isEmpty {
          Divider().padding(.vertical, 6)
          header("Installed")
          ForEach(app.installed) { model in
            HStack {
              Button {
                if let entry = app.catalog?.model(model.id) { choose(entry) }
              } label: {
                HStack {
                  if app.active?.id == model.id {
                    Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.tint)
                  }
                  Text(model.name)
                  Text(model.quant.rawValue).foregroundStyle(.secondary)
                  Spacer()
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Use \(model.name)")
              Button(role: .destructive) { app.remove(model) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Remove \(model.name) and free \(ModelPlanner.gb(model.bytes))")
                .accessibilityLabel("Remove \(model.name)")
            }
            .font(.callout).padding(.horizontal, 10).padding(.vertical, 3)
          }
        }
      }
      .padding(8)
    }
    .frame(width: 380, height: 460)
  }

  private func choose(_ model: CatalogModel) {
    app.select(model)
    close()
  }

  private func header(_ text: String) -> some View {
    Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
      .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
  }
}

private struct Row: View {
  let title: String
  let subtitle: String
  let option: ModelOption
  let active: Bool
  let action: () -> Void
  @State private var hover = false

  var body: some View {
    Button(action: action) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 1) {
          Text(title).fontWeight(.medium)
          Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        badge
      }
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(RoundedRectangle(cornerRadius: 6).fill(hover && enabled ? Color.primary.opacity(0.07) : .clear))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .opacity(enabled ? 1 : 0.5)
    .onHover { hover = $0 }
    .help(help)
  }

  private var enabled: Bool {
    if case .incompatible = option.state { false } else { true }
  }

  private var help: String {
    switch option.state {
    case .incompatible(let reason): reason
    case .notInstalled: option.plan?.reason ?? ""
    case .chatOnly: "Installed. It cannot call tools, so it is for chat only."
    case .ready: "Installed and verified."
    }
  }

  @ViewBuilder private var badge: some View {
    switch option.state {
    case .ready:
      if active { Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.tint) }
      else { Text("Installed").font(.caption).foregroundStyle(.secondary) }
    case .chatOnly: Text("Chat only").font(.caption).foregroundStyle(.orange)
    case .notInstalled(let bytes):
      Label(ModelPlanner.gb(bytes), systemImage: "arrow.down.circle").font(.caption).foregroundStyle(.secondary)
    case .incompatible: Text("Too large").font(.caption).foregroundStyle(.secondary)
    }
  }
}
