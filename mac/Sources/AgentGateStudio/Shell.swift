import AgentGateCore
import SwiftUI

/// Sidebar, title bar and page area, laid out like the desktop web app.
struct Shell: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    @Bindable var app = app
    HStack(spacing: 0) {
      Sidebar().frame(width: 232)
      Rectangle().fill(Theme.line).frame(width: 1)
      VStack(spacing: 0) {
        TitleBar()
        if let error = app.errorMessage {
          HStack {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.danger)
            Spacer()
            Button { app.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
          }
          .font(.system(size: 13)).padding(.horizontal, 28).padding(.vertical, 8).background(Theme.danger.opacity(0.08))
        }
        page.frame(maxWidth: .infinity, maxHeight: .infinity)
        AgentStrip()
        InstallStrip()
      }
      .background(Theme.bg)
    }
    .background(Theme.sidebar)
    .foregroundStyle(Theme.text)
    .preferredColorScheme(.dark)
    .ignoresSafeArea()
    .sheet(isPresented: $app.paletteOpen) { CommandPalette().environment(app) }
    .sheet(isPresented: $app.agentPanelOpen) { AgentPanel().environment(app) }
    .sheet(item: $app.stepDetail) { StepSheet(step: $0).environment(app) }
    .sheet(isPresented: $app.activityOpen) { ActivitySheet().environment(app) }
  }

  @ViewBuilder private var page: some View {
    switch app.route {
    case .workspace: WorkspacePage()
    case .project(let id): ProjectPage(projectId: id)
    case .session(let id): SessionPage(sessionId: id)
    case .security: SecurityPage()
    case .models: ModelsPage()
    case .profile: ProfilePage()
    }
  }
}

private struct Sidebar: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Room for the window's traffic lights.
      Spacer().frame(height: 52)
      Button { app.route = .workspace } label: {
        HStack(spacing: 8) {
          Image(systemName: "cube").font(.system(size: 20)).foregroundStyle(Theme.accent)
          Text("AGENTGATE").font(.system(size: 13, weight: .semibold))
          Text("Studio").font(.system(size: 13)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 26)
      }
      .buttonStyle(.plain)
      VStack(spacing: 6) {
        NavRow(title: "Workspace", symbol: "house", selected: workspaceSelected) { app.route = .workspace }
        NavRow(title: "Security & Verification", symbol: "checkmark.shield", selected: app.route == .security) {
          app.route = .security
        }
      }
      .padding(.horizontal, 14).padding(.top, 30)
      HStack {
        Text("Projects").font(.system(size: 12)).foregroundStyle(Theme.muted)
        Spacer()
        Button { app.route = .workspace } label: { Image(systemName: "plus").font(.system(size: 13)) }
          .buttonStyle(.plain).foregroundStyle(Theme.muted).accessibilityLabel("Create project")
      }
      .padding(.horizontal, 27).padding(.top, 34).padding(.bottom, 10)
      ScrollView {
        VStack(spacing: 4) {
          ForEach(app.projects) { project in
            ProjectRow(project: project, selected: projectSelected(project.id)) { app.route = .project(project.id) }
          }
          if app.projects.isEmpty {
            Text("Create a project to begin.").font(.system(size: 12)).foregroundStyle(Theme.muted)
              .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 13)
          }
        }
        .padding(.horizontal, 14)
      }
      Spacer(minLength: 0)
      Button { app.route = .profile } label: {
        HStack(spacing: 12) {
          Image(systemName: "person.crop.circle").font(.system(size: 15)).foregroundStyle(Theme.muted)
            .frame(width: 34, height: 34).background(Circle().fill(Theme.raised))
          VStack(alignment: .leading, spacing: 3) {
            Text("Profile").font(.system(size: 12, weight: .semibold))
            Text(app.agentOn ? "Agent on · \(app.providerKeys.count) key\(app.providerKeys.count == 1 ? "" : "s")" : "Add an API key")
              .font(.system(size: 11)).foregroundStyle(app.agentOn ? Theme.muted : Theme.accent)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain).accessibilityLabel("Profile")
      .padding(.horizontal, 26).padding(.bottom, 22)
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Theme.sidebar)
  }

  private var workspaceSelected: Bool {
    switch app.route {
    case .workspace, .project, .session: true
    default: false
    }
  }

  private func projectSelected(_ id: UUID) -> Bool {
    switch app.route {
    case .project(let p): p == id
    case .session(let s): app.session(s)?.projectId == id
    default: false
    }
  }
}

private struct NavRow: View {
  let title: String
  let symbol: String
  let selected: Bool
  let action: () -> Void
  @State private var hover = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(selected ? Theme.accent : Theme.muted)
          .frame(width: 18)
        Text(title).font(.system(size: 13)).foregroundStyle(selected ? Theme.text : Theme.text.opacity(0.85))
          .lineLimit(1).fixedSize()
        Spacer()
      }
      .padding(.horizontal, 13).frame(height: 42)
      .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.raised : hover ? Theme.raised.opacity(0.5) : .clear))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
    .accessibilityLabel(title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

private struct ProjectRow: View {
  let project: Project
  let selected: Bool
  let action: () -> Void
  @State private var hover = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Circle().strokeBorder(selected ? Theme.accent : Theme.muted, lineWidth: 1)
          .background(Circle().fill(selected ? Theme.accent : .clear)).frame(width: 6, height: 6)
        Text(project.name).font(.system(size: 12.5)).lineLimit(1)
        Spacer()
      }
      .padding(.horizontal, 13).frame(height: 38)
      .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.raised : hover ? Theme.raised.opacity(0.5) : .clear))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
    .accessibilityLabel("Project \(project.name)")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

private struct TitleBar: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    HStack(spacing: 22) {
      HStack(spacing: 12) {
        Text("Studio")
        Text("/").foregroundStyle(Theme.muted.opacity(0.6))
        Text(crumb)
      }
      .font(.system(size: 12)).foregroundStyle(Theme.muted)
      Spacer()
      Button { app.route = .models } label: {
        Label("Models", systemImage: "cube").font(.system(size: 13))
      }
      .buttonStyle(.plain).accessibilityLabel("Models")
      Button { app.paletteOpen = true } label: {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass").font(.system(size: 14))
          Text("⌘ K").font(.system(size: 10, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.raised))
        }
      }
      .buttonStyle(.plain).accessibilityLabel("Open command palette")
      Button { app.route = .profile } label: {
        Image(systemName: "person.crop.circle").font(.system(size: 17))
          .foregroundStyle(app.route == .profile ? Theme.accent : Theme.text)
      }
      .buttonStyle(.plain).accessibilityLabel("Profile").help("Profile: API keys, agent and shortcuts")
    }
    .foregroundStyle(Theme.text)
    .padding(.horizontal, 28).frame(height: 56)
    .background(Theme.bg)
    .overlay(alignment: .bottom) { Rectangle().fill(Theme.line.opacity(0.4)).frame(height: 1) }
  }

  private var crumb: String {
    switch app.route {
    case .security: "Security & Verification"
    case .models: "Providers"
    case .profile: "Profile"
    default: "Workspace"
    }
  }
}


private struct CommandPalette: View {
  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  private var items: [(label: String, symbol: String, route: Route)] {
    let fixed: [(String, String, Route)] = [
      ("Workspace", "house", .workspace), ("Security & Verification", "checkmark.shield", .security),
      ("Models & Providers", "cube", .models),
    ]
    let all = fixed + app.projects.map { ($0.name, "bubble.left", Route.project($0.id)) }
    return all.filter { query.isEmpty || $0.0.localizedCaseInsensitiveContains(query) }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
        TextField("Go to a project or view…", text: $query).textFieldStyle(.plain).font(.system(size: 15))
          .onSubmit { if let first = items.first { go(first.route) } }
      }
      .padding(16)
      Rectangle().fill(Theme.line).frame(height: 1)
      ScrollView {
        VStack(spacing: 2) {
          ForEach(items, id: \.label) { item in
            Button { go(item.route) } label: {
              HStack(spacing: 12) {
                Image(systemName: item.symbol).foregroundStyle(Theme.muted).frame(width: 18)
                Text(item.label)
                Spacer()
              }
              .font(.system(size: 13)).padding(.horizontal, 12).frame(height: 36).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
        .padding(8)
      }
      .frame(height: 260)
    }
    .frame(width: 520).background(Theme.surface).preferredColorScheme(.dark)
    .onExitCommand { dismiss() }
  }

  private func go(_ route: Route) {
    app.route = route
    dismiss()
  }
}
