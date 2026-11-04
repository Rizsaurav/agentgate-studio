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

  var body: some View {
    PageScroll {
      VStack(alignment: .leading, spacing: 36) {
        PageHeading(
          eyebrow: "Your local workspace", title: "A place for your next idea.",
          detail: "Continue a conversation, bring your context, and put your models to work.")
        HStack(alignment: .top, spacing: 40) {
          VStack(alignment: .leading, spacing: 14) {
            HStack {
              Text("Projects").font(.system(size: 16, weight: .semibold))
              Spacer()
              Text("\(app.projects.count) saved locally").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            if app.projects.isEmpty {
              Card {
                VStack(spacing: 10) {
                  IconTile(symbol: "house")
                  Text("Start with a project").font(.system(size: 15, weight: .semibold))
                  Text("A persistent home for conversations, models, and shared context.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 30)
              }
            }
            ForEach(app.projects) { project in
              ProjectListRow(project: project, sessions: app.sessions(in: project.id).count) {
                app.route = .project(project.id)
              }
            }
          }
          Card(padding: 26) {
            VStack(alignment: .leading, spacing: 16) {
              Text("Make room for something new").font(.system(size: 11)).foregroundStyle(Theme.muted)
              Text("New project").font(.system(size: 19, weight: .semibold))
              VStack(alignment: .leading, spacing: 10) {
                Text("Project name").font(.system(size: 14, weight: .medium))
                TextField("e.g. Reference RAG", text: $name).field().onSubmit(create)
                  .accessibilityLabel("Project name")
              }
              Text("A local workspace for your project. You can reopen it later.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
              Button(action: create) { Label("Create project", systemImage: "arrow.up.right").labelStyle(TrailingIcon()) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
          }
          .frame(width: 320)
        }
        HStack(spacing: 10) {
          Image(systemName: "key").foregroundStyle(Theme.muted)
          Text("Saved locally. Models run on this Mac in the engine built into the app.")
            .font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
      }
    }
  }

  private func create() {
    if app.createProject(named: name) { name = "" }
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
        IconTile(symbol: "cube", size: 46)
        VStack(alignment: .leading, spacing: 6) {
          Text(project.name).font(.system(size: 14, weight: .semibold))
          Text("\(plural(sessions, "session"))  ·  Created \(isoDay(project.createdAt))")
            .font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        Spacer()
        Image(systemName: "arrow.up.right").font(.system(size: 12)).foregroundStyle(Theme.muted)
      }
      .padding(8)
      .background(RoundedRectangle(cornerRadius: 12).fill(hover ? Theme.surface : .clear))
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
          PageHeading(
            eyebrow: "Project workspace", title: project.name,
            detail: "\(plural(app.sessions(in: projectId).count, "session")) · Models run on this Mac")
          HStack(alignment: .top, spacing: 36) {
            VStack(alignment: .leading, spacing: 14) {
              HStack {
                Text("Agent sessions").font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("Persisted on this computer").font(.system(size: 12)).foregroundStyle(Theme.muted)
              }
              let sessions = app.sessions(in: projectId)
              if sessions.isEmpty {
                Card {
                  VStack(spacing: 12) {
                    IconTile(symbol: "bubble.left", size: 58)
                    Text("Your next conversation starts here.").font(.system(size: 15, weight: .semibold))
                    Text("Choose an installed model to start. Install one from Models if the list is empty.")
                      .font(.system(size: 13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                      .frame(maxWidth: 340)
                  }
                  .frame(maxWidth: .infinity).padding(.vertical, 26)
                }
              }
              ForEach(sessions) { session in
                SessionListRow(session: session) { app.route = .session(session.id) }
              }
            }
            Card(padding: 24) {
              VStack(alignment: .leading, spacing: 14) {
                Text("New conversation").font(.system(size: 16, weight: .semibold))
                if app.installed.isEmpty {
                  Text("No model is installed yet.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                  Button("Install a model") { app.route = .models }.buttonStyle(PrimaryButtonStyle())
                } else {
                  Text("Model").font(.system(size: 14, weight: .medium))
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
                  Button("Start session") {
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
