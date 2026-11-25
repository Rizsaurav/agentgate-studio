import AgentGateCore
import SwiftUI

/// What the agent may do beyond reading, editing and running commands. Everything starts off; each card says
/// what turning it on costs and what, if anything, leaves this Mac.
struct CapabilitiesPage: View {
  @Environment(AppModel.self) private var app
  @State private var serverName = ""
  @State private var serverCommand = ""
  @State private var serverError: String?

  var body: some View {
    PageScroll {
      VStack(alignment: .leading, spacing: 26) {
        PageHeading(
          eyebrow: "Agent", title: "Capabilities",
          detail: "Turn on only what you use. Each one adds instructions the local model reads before every answer, so fewer is faster. Every call still passes the gate.")
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
          ForEach(Self.toggles, id: \.title) { item in
            CapabilityCard(item: item, isOn: binding(item.key))
          }
        }
        mcp
        hardening
      }
      .frame(maxWidth: 900, alignment: .leading)
    }
  }

  struct Toggle {
    let key: WritableKeyPath<AgentCapabilities, Bool>
    let symbol: String
    let title: String
    let detail: String
    var leavesMac: String?
    var experimental = false
  }

  static let toggles: [Toggle] = [
    .init(key: \.todos, symbol: "checklist", title: "To-do list",
          detail: "For tasks with several steps the agent keeps a checklist, shown in the chat as it ticks items off."),
    .init(key: \.subagents, symbol: "person.2", title: "Helper agents",
          detail: "The agent can hand a separate part of a big task to a helper with its own context, running in the background.",
          experimental: true),
    .init(key: \.skills, symbol: "book", title: "Project skills",
          detail: "Reusable instructions in the project's .agents/skills/<name>/SKILL.md, loaded only when a task needs them."),
    .init(key: \.codeNavigation, symbol: "arrow.triangle.branch", title: "Code navigation",
          detail: "Definitions, references and hover docs from language servers already installed on this Mac. Nothing is downloaded.",
          experimental: true),
    .init(key: \.webFetch, symbol: "globe", title: "Fetch web pages",
          detail: "The agent may read a public page, such as library docs, after you approve the address. Private and local addresses are refused.",
          leavesMac: "The address you approve"),
    .init(key: \.webSearch, symbol: "magnifyingglass", title: "Web search",
          detail: "The agent may search the web for documentation. Each search waits for your approval.",
          leavesMac: "Search queries, to Exa"),
  ]

  private func binding(_ key: WritableKeyPath<AgentCapabilities, Bool>) -> Binding<Bool> {
    Binding(get: { app.capabilities[keyPath: key] }, set: { value in
      var changed = app.capabilities
      changed[keyPath: key] = value
      app.setCapabilities(changed)
    })
  }

  private var mcp: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: "puzzlepiece.extension").foregroundStyle(Theme.accent)
        Text("MCP servers").font(.system(size: 16, weight: .semibold))
      }
      Text("Model Context Protocol servers give the agent extra tools. Each server is a command started on this Mac, inside the agent's sandbox, and every tool call asks you first. A project cannot add servers; only you can, here.")
        .font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
      Card(padding: 16) {
        VStack(alignment: .leading, spacing: 12) {
          if app.capabilities.mcpServers.isEmpty {
            Text("No servers yet.").font(.system(size: 13)).foregroundStyle(Theme.muted)
          }
          ForEach(app.capabilities.mcpServers) { server in
            HStack(spacing: 10) {
              Circle().fill(server.enabled ? Theme.success : Theme.muted).frame(width: 8, height: 8)
              Text(server.name).font(.system(size: 13, weight: .semibold))
              Text(server.command.joined(separator: " ")).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
              Spacer()
              SwiftUI.Toggle("", isOn: serverBinding(server.id)).labelsHidden().toggleStyle(.switch).controlSize(.small)
              Button { remove(server.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                .foregroundStyle(Theme.muted).help("Remove \(server.name)")
            }
          }
          Divider().overlay(Theme.line)
          HStack(spacing: 8) {
            TextField("name", text: $serverName).field().frame(width: 140).accessibilityLabel("Server name")
            TextField("command, e.g. npx -y @modelcontextprotocol/server-memory", text: $serverCommand).field()
              .accessibilityLabel("Server command")
            Button("Add") { add() }.buttonStyle(SubtleButtonStyle())
              .disabled(serverName.isEmpty || serverCommand.trimmingCharacters(in: .whitespaces).isEmpty)
          }
          if let serverError {
            Text(serverError).font(.system(size: 12)).foregroundStyle(Theme.danger)
          }
        }
      }
    }
  }

  private var hardening: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: "lock.shield").foregroundStyle(Theme.success)
        Text("Always on").font(.system(size: 16, weight: .semibold))
      }
      Card(padding: 16) {
        VStack(alignment: .leading, spacing: 9) {
          Hardened(text: "A project's own agent configuration is ignored, so a cloned repository cannot loosen the rules or start servers.")
          Hardened(text: "Your personal assistant settings and skills in your home folder stay out of the agent.")
          Hardened(text: "A command that runs longer than \(AgentCapabilities.commandTimeout / 60) minutes is stopped and the model is told.")
          Hardened(text: "The same call repeated several times in a row is refused, so a stuck loop stops spending the turn.")
          Hardened(text: "Nothing is downloaded behind your back: no model lists, language servers or updates.")
        }
      }
    }
  }

  private func serverBinding(_ id: UUID) -> Binding<Bool> {
    Binding(get: { app.capabilities.mcpServers.first { $0.id == id }?.enabled ?? false }, set: { value in
      var changed = app.capabilities
      if let index = changed.mcpServers.firstIndex(where: { $0.id == id }) { changed.mcpServers[index].enabled = value }
      app.setCapabilities(changed)
    })
  }

  private func add() {
    let name = serverName.trimmingCharacters(in: .whitespaces).lowercased()
    guard AgentCapabilities.MCPServer.isValidName(name) else {
      serverError = "Use a short name of lowercase letters, digits and dashes, starting with a letter."
      return
    }
    guard !app.capabilities.mcpServers.contains(where: { $0.name == name }) else {
      serverError = "A server named \(name) already exists."
      return
    }
    let command = CommandLineWords.split(serverCommand)
    guard !command.isEmpty else { serverError = "Give the command that starts the server."; return }
    var changed = app.capabilities
    changed.mcpServers.append(.init(name: name, command: command))
    app.setCapabilities(changed)
    serverName = ""
    serverCommand = ""
    serverError = nil
  }

  private func remove(_ id: UUID) {
    var changed = app.capabilities
    changed.mcpServers.removeAll { $0.id == id }
    app.setCapabilities(changed)
  }
}

private struct CapabilityCard: View {
  let item: CapabilitiesPage.Toggle
  @Binding var isOn: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Image(systemName: item.symbol).font(.system(size: 14, weight: .medium))
          .foregroundStyle(isOn ? Color(hex: 0x15121F) : Theme.accent)
          .frame(width: 32, height: 32)
          .background(RoundedRectangle(cornerRadius: 9).fill(isOn ? Theme.accent : Theme.accent.opacity(0.1)))
        Text(item.title).font(.system(size: 14, weight: .semibold))
        if item.experimental { StatusPill(text: "Experimental", tone: .neutral) }
        Spacer()
        SwiftUI.Toggle(item.title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
      }
      Text(item.detail).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      HStack(spacing: 6) {
        Image(systemName: item.leavesMac == nil ? "lock" : "arrow.up.forward.app").font(.system(size: 10))
        Text(item.leavesMac.map { "Leaves this Mac: \($0)" } ?? "Stays on this Mac")
      }
      .font(.system(size: 11)).foregroundStyle(item.leavesMac == nil ? Theme.success : Theme.warning)
    }
    .padding(16)
    .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(isOn ? Theme.accent.opacity(0.45) : Theme.line.opacity(0.5)))
  }
}

private struct Hardened: View {
  let text: String
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.success)
      Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
    }
  }
}
