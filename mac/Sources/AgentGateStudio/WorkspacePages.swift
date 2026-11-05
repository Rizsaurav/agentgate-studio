import AgentGateCore
import SwiftUI

func plural(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }

private func isoDay(_ date: Date) -> String {
  date.formatted(.iso8601.year().month().day())
}

/// Page padding and width shared by every page.
struct PageScroll<Content: View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    ScrollView {
      content.padding(.horizontal, 42).padding(.top, 40).padding(.bottom, 32)
        .frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollContentBackground(.hidden)
  }
}

struct WorkspacePage: View {
  @Environment(AppModel.self) private var app
  @State private var name = ""
  @FocusState private var nameFocused: Bool

  var body: some View {
    PageScroll {
      VStack(alignment: .leading, spacing: 28) {
        Text("Projects").font(.system(size: 28, weight: .semibold)).tracking(-0.6)
        if !setupDone { SetupCard() }
        HStack(spacing: 10) {
          TextField("Project name", text: $name, prompt: Text(""))
            .inputHint(app.projects.isEmpty ? "Name your first project" : "New project", when: name.isEmpty)
            .field().onSubmit(create).accessibilityLabel("Project name").focused($nameFocused)
          Button(action: create) { Label("Create project", systemImage: "plus").labelStyle(.iconOnly) }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            .help("Create project")
        }
        Button("Open a folder…") { app.openFolder() }.buttonStyle(.plain).foregroundStyle(Theme.accent)
          .font(.system(size: 13))
        VStack(spacing: 8) {
          ForEach(app.projects) { project in
            ProjectListRow(project: project, sessions: app.sessions(in: project.id).count) {
              app.route = .project(project.id)
            }
          }
        }
      }
      .frame(maxWidth: 640, alignment: .leading)
    }
    .onAppear { nameFocused = true }
  }

  private var setupDone: Bool { !app.installed.isEmpty && app.agentOn }

  private func create() {
    if app.createProject(named: name) { name = "" }
  }
}

/// First-run checklist: a model, then the optional repair agent. Disappears once both are settled.
private struct SetupCard: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    Card(padding: 8) {
      VStack(spacing: 0) {
        row(done: !app.installed.isEmpty, title: app.active?.name ?? app.installed.first?.name ?? "Model") {
          Button("Choose a model") { app.route = .models }.buttonStyle(PrimaryButtonStyle())
        }
        Divider().overlay(Theme.line)
        row(done: app.agentOn, title: "Agent (an API key)") {
          Button("Add a key") { app.route = .profile }.buttonStyle(PrimaryButtonStyle())
        }
      }
    }
  }

  private func row<Trailing: View>(done: Bool, title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
    HStack(spacing: 12) {
      Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? Theme.accent : Theme.muted)
      Text(title).font(.system(size: 14, weight: .medium))
      Spacer()
      if !done { trailing() }
    }
    .padding(12)
  }
}

/// Puts the icon after the title, like "Create project ↗".
struct TrailingIcon: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 10) {
      configuration.title
      configuration.icon.font(.system(size: 12))
    }
  }
}

private struct ProjectListRow: View {
  let project: Project
  let sessions: Int
  let action: () -> Void
  @State private var hover = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 16) {
        IconTile(symbol: "folder", size: 40)
        VStack(alignment: .leading, spacing: 6) {
          Text(project.name).font(.system(size: 14, weight: .semibold))
          Text("\(plural(sessions, "chat"))" + (project.folder.map { "  ·  " + ($0 as NSString).abbreviatingWithTildeInPath } ?? ""))
            .font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        Spacer()
        Image(systemName: "arrow.up.right").font(.system(size: 12)).foregroundStyle(Theme.muted)
      }
      .padding(14)
      .background(RoundedRectangle(cornerRadius: 14).fill(hover ? Theme.raised : Theme.surface))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
    .accessibilityLabel("Open \(project.name)")
  }
}

struct ProjectPage: View {
  @Environment(AppModel.self) private var app
  let projectId: UUID
  @State private var modelId = ""

  var body: some View {
    if let project = app.project(projectId) {
      PageScroll {
        VStack(alignment: .leading, spacing: 30) {
          Button { app.route = .workspace } label: { Text("← All projects").font(.system(size: 13)) }
            .buttonStyle(.plain).foregroundStyle(Theme.muted)
          Text(project.name).font(.system(size: 28, weight: .semibold)).tracking(-0.6)
          HStack(alignment: .top, spacing: 36) {
            VStack(alignment: .leading, spacing: 14) {
              let sessions = app.sessions(in: projectId)
              ForEach(sessions) { session in
                SessionListRow(session: session) { app.route = .session(session.id) }
              }
            }
            Card(padding: 24) {
              VStack(alignment: .leading, spacing: 14) {
                if app.installed.isEmpty {
                  Button("Choose a model") { app.route = .models }.buttonStyle(PrimaryButtonStyle())
                } else {
                  Menu {
                    ForEach(app.installed) { model in
                      Button("\(model.name) · \(model.quant.rawValue)") { modelId = model.id }
                    }
                  } label: {
                    HStack {
                      Text(selectedLabel).font(.system(size: 14)).foregroundStyle(Theme.text)
                      Spacer()
                      Image(systemName: "chevron.up.chevron.down").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
                    .contentShape(Rectangle())
                  }
                  .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                  .accessibilityLabel("Model")
                  .onAppear { if modelId.isEmpty { modelId = app.active?.id ?? app.installed.first?.id ?? "" } }
                  Button("New chat") {
                    if let model = app.installed.first(where: { $0.id == modelId }) {
                      app.startSession(in: projectId, with: model)
                    }
                  }
                  .buttonStyle(PrimaryButtonStyle())
                }
              }
            }
            .frame(width: 300)
          }
        }
      }
    } else {
      Text("This project no longer exists.").foregroundStyle(Theme.muted)
    }
  }

  private var selectedLabel: String {
    app.installed.first { $0.id == modelId }.map { "\($0.name) · \($0.quant.rawValue)" } ?? "Choose a model"
  }
}

private struct SessionListRow: View {
  let session: Session
  let action: () -> Void
  @State private var hover = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 14) {
        IconTile(symbol: "bubble.left", size: 40)
        VStack(alignment: .leading, spacing: 5) {
          Text(session.messages.first?.content ?? "New session").font(.system(size: 14, weight: .medium)).lineLimit(1)
          Text("\(session.modelName)  ·  \(plural(session.messages.filter { $0.role == .user }.count, "task"))  ·  \(isoDay(session.createdAt))")
            .font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        Spacer()
        Image(systemName: "arrow.up.right").font(.system(size: 12)).foregroundStyle(Theme.muted)
      }
      .padding(10)
      .background(RoundedRectangle(cornerRadius: 12).fill(hover ? Theme.surface : .clear))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
    .accessibilityLabel("Open session")
  }
}
