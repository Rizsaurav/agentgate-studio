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
        CloneField()
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

/// Adds a project from a Git URL: checked first, cloned shallow with progress, cancellable.
private struct CloneField: View {
  @Environment(AppModel.self) private var app
  @State private var url = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        TextField("Git URL", text: $url, prompt: Text(""))
          .inputHint("Or paste a Git URL, e.g. https://github.com/owner/repo", when: url.isEmpty)
          .field().onSubmit(clone).accessibilityLabel("Git URL").disabled(app.cloneProgress != nil)
        if app.cloneProgress != nil {
          Button("Cancel") { app.cancelClone() }.buttonStyle(SubtleButtonStyle())
        } else {
          Button("Clone", action: clone).buttonStyle(SubtleButtonStyle())
            .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
      if let progress = app.cloneProgress {
        ProgressView(value: progress).progressViewStyle(.linear).tint(Theme.accent)
        Text("Downloading the latest version (shallow clone). Full history can be fetched later.")
          .font(.system(size: 12)).foregroundStyle(Theme.muted)
      }
      if let error = app.cloneError {
        Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func clone() {
    app.cloneProject(from: url)
  }
}

/// What was detected about a project, editable so the user can correct it.
private struct ProjectSummaryCard: View {
  @Environment(AppModel.self) private var app
  let project: Project
  @State private var draft = ProjectSummary(language: "", packageManager: "", testCommand: "", ci: "")
  @State private var fetching = false

  var body: some View {
    Card(padding: 18) {
      VStack(alignment: .leading, spacing: 10) {
        Text("About this project").font(.system(size: 13, weight: .semibold))
        Text("Detected from the project's files when it was added. Correct anything that is wrong.")
          .font(.system(size: 12)).foregroundStyle(Theme.muted)
        row("Language", $draft.language)
        row("Package manager", $draft.packageManager)
        row("Test command", $draft.testCommand)
        row("CI", $draft.ci)
        HStack {
          Button("Save") { app.updateSummary(of: project.id, to: draft) }
            .buttonStyle(SubtleButtonStyle()).disabled(draft == project.summary)
          if let folder = project.folder, GitCloner.isShallow(URL(fileURLWithPath: folder)) {
            Button(fetching ? "Fetching history…" : "Fetch full history") {
              fetching = true
              Task { await app.fetchFullHistory(of: project.id); fetching = false }
            }
            .buttonStyle(SubtleButtonStyle()).disabled(fetching)
            .help("This project was cloned with only its latest version. Download every earlier commit too.")
          }
        }
      }
    }
    .onAppear { draft = project.summary ?? draft }
  }

  private func row(_ label: String, _ value: Binding<String>) -> some View {
    HStack {
      Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted).frame(width: 120, alignment: .leading)
      TextField(label, text: value, prompt: Text("Unknown")).textFieldStyle(.roundedBorder).font(.system(size: 12))
    }
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
  @AppStorage("projectTab") private var tab = "chats"

  var body: some View {
    if let project = app.project(projectId) {
      PageScroll {
        VStack(alignment: .leading, spacing: 30) {
          Button { app.route = .workspace } label: { Text("← All projects").font(.system(size: 13)) }
            .buttonStyle(.plain).foregroundStyle(Theme.muted)
          Text(project.name).font(.system(size: 28, weight: .semibold)).tracking(-0.6)
          if project.summary != nil { ProjectSummaryCard(project: project).frame(maxWidth: 640).id(project.id) }
          Picker("View", selection: $tab) {
            Text("Chats").tag("chats")
            Text("CI/CD").tag("ci")
          }
          .pickerStyle(.segmented).frame(width: 220).labelsHidden()
          if tab == "ci" {
            if let folder = project.folder {
              CIPanel(projectId: projectId, folder: URL(fileURLWithPath: folder)).id(projectId)
            } else {
              Text("This project has no folder. Open a folder to see its CI.").foregroundStyle(Theme.muted)
            }
          } else {
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
