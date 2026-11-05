import AgentGateCore
import SwiftUI

/// What an agent may do, one line per capability, with a tick or a cross.
struct PermissionList: View {
  let role: AgentRole
  let access: ProjectAccess

  var body: some View {
    let allowed = AgentPermissions.effective(role, project: access)
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Capability.allCases, id: \.self) { capability in
        let on = allowed.contains(capability)
        HStack(spacing: 8) {
          Image(systemName: on ? "checkmark.circle.fill" : "xmark.circle")
            .foregroundStyle(on ? Theme.accent : Theme.muted)
            .accessibilityHidden(true)
          Text(capability.label).font(.system(size: 12))
            .foregroundStyle(on ? Theme.text : Theme.muted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(capability.label): \(on ? "allowed" : "not allowed")")
      }
    }
  }
}

/// The project's access setting and what the coding agent may do with it.
struct ProjectAccessCard: View {
  @Environment(AppModel.self) private var app
  let project: Project

  var body: some View {
    Card(padding: 20) {
      VStack(alignment: .leading, spacing: 12) {
        Text("Agent permissions").font(.system(size: 14, weight: .semibold))
        Picker("Access", selection: Binding(
          get: { project.effectiveAccess },
          set: { app.setAccess($0, for: project.id) }
        )) {
          ForEach(ProjectAccess.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented).frame(width: 320).labelsHidden()
        Text(project.effectiveAccess.summary).font(.system(size: 12)).foregroundStyle(Theme.muted)
          .fixedSize(horizontal: false, vertical: true)
        Text("Coding agent").font(.system(size: 12, weight: .medium))
        PermissionList(role: .coder, access: project.effectiveAccess)
        Text("The supervising agent never changes project files or runs commands here.")
          .font(.system(size: 11)).foregroundStyle(Theme.muted)
      }
    }
  }
}
