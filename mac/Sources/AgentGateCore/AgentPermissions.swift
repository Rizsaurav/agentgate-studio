import Foundation

/// Something an agent can do. Each harness tool maps to exactly one.
public enum Capability: String, Codable, Sendable, CaseIterable {
  /// Read, list and search files in the project.
  case read
  /// Create, change or delete files in the project.
  case edit
  /// Run commands in the project folder.
  case shell
  /// Reach the internet (from commands, or from the agent's own web search).
  case network
  /// Change how models are installed and run: downloads, quantization, engine settings.
  case installSettings

  public var label: String {
    switch self {
    case .read: "Read and search project files"
    case .edit: "Change project files"
    case .shell: "Run commands in the project"
    case .network: "Use the internet"
    case .installSettings: "Change model installs and engine settings"
    }
  }

  /// The capability a harness tool needs; nil for a tool this app does not know, which is never allowed.
  public static func forTool(_ tool: String) -> Capability? {
    switch tool {
    case "read", "glob", "grep", "list": .read
    case "edit", "write", "patch", "multiedit": .edit
    case "bash": .shell
    case "webfetch", "websearch": .network
    default: nil
    }
  }
}

/// How much the agents may do in one project. Set on the project page; a project can only narrow what an agent may do.
public enum ProjectAccess: String, Codable, Sendable, CaseIterable {
  case full, noNetwork, readOnly

  public var title: String {
    switch self {
    case .full: "Full"
    case .noNetwork: "No network"
    case .readOnly: "Read only"
    }
  }

  public var summary: String {
    switch self {
    case .full: "The coding agent can read, change files and run commands, with your approval."
    case .noNetwork: "As Full, but nothing run in this project can reach the internet."
    case .readOnly: "The coding agent can only read and search. No edits, no commands."
    }
  }

  /// What the project allows. Install settings are not about the project, so a project neither grants nor removes them.
  public var allows: Set<Capability> {
    switch self {
    case .full: [.read, .edit, .shell, .network]
    case .noNetwork: [.read, .edit, .shell]
    case .readOnly: [.read]
    }
  }
}

/// Which agent may do what. Fixed in code: no setting can give an agent a capability its role does not have.
public enum AgentPermissions {
  /// The most each role may ever do.
  public static func base(_ role: AgentRole) -> Set<Capability> {
    switch role {
    // Watches installs, searches the web and chooses fixes. Never edits project files or runs commands in them.
    case .supervisor: [.read, .network, .installSettings]
    // Works on the project. Never changes how models are installed or run.
    case .coder: [.read, .edit, .shell, .network]
    // Runs predefined repair operations on installs only.
    case .repair: [.installSettings]
    case .reviewer: [.read]
    }
  }

  /// What a role may do in a project with the given access.
  public static func effective(_ role: AgentRole, project: ProjectAccess) -> Set<Capability> {
    base(role).intersection(project.allows.union([.installSettings]))
  }

  /// Checks one tool call. Unknown tools are refused.
  public static func check(tool: String, role: AgentRole, project: ProjectAccess) -> ToolPolicy.Verdict {
    guard let capability = Capability.forTool(tool) else {
      return .block(rule: "unknown-tool", reason: "\"\(tool)\" is not a tool this app allows.")
    }
    return check(capability, role: role, project: project)
  }

  public static func check(_ capability: Capability, role: AgentRole, project: ProjectAccess) -> ToolPolicy.Verdict {
    guard base(role).contains(capability) else {
      return .block(rule: "not-allowed-for-agent",
                    reason: "The \(role.rawValue) agent may never: \(capability.label.lowercased()).")
    }
    guard effective(role, project: project).contains(capability) else {
      return .block(rule: "not-allowed-in-project",
                    reason: "This project is \(project.title.lowercased()): \(capability.label.lowercased()) is off.")
    }
    return .allow
  }

  /// The coding agent's harness rules for a project. Anything the project turns off is denied by the harness itself,
  /// so the model is never even asked. Reads always ask, so the app checks each one. The harness's web tool stays
  /// off: the network is for commands only.
  public static func harnessRules(_ project: ProjectAccess) -> [String: String] {
    let can = effective(.coder, project: project)
    return [
      "bash": can.contains(.shell) ? "ask" : "deny",
      "edit": can.contains(.edit) ? "ask" : "deny",
      "read": "ask", "glob": "ask", "grep": "ask", "list": "ask",
      "webfetch": "deny",
      "external_directory": "deny",
    ]
  }

  /// Whether commands in this project's sandbox may reach the internet. The local engine on this Mac is always reachable.
  public static func sandboxNetwork(_ project: ProjectAccess) -> Bool {
    effective(.coder, project: project).contains(.network)
  }
}
