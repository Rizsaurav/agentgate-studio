import AgentGateCore
import SwiftUI

@main
struct AgentGateStudioApp: App {
  var body: some Scene {
    WindowGroup("AGENTGATE Studio") {
      HardwareView()
        .frame(minWidth: 720, minHeight: 480)
    }
  }
}

struct HardwareView: View {
  @State private var result: Result<HardwareProfile, Error>?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("This Mac", systemImage: "desktopcomputer").font(.headline)
      switch result {
      case .none:
        ProgressView("Detecting hardware…")
      case .success(let profile):
        Text(profile.summary).font(.title3)
        Text("Up to \(gigabytes(profile.modelBudgetBytes)) for a model")
          .foregroundStyle(.secondary)
        if let notice = profile.notice {
          Label(notice, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
      case .failure(let error):
        Label(String(describing: error), systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task { result = Result { try HardwareProbe.current(modelsDirectory: AppPaths.models) } }
  }

  private func gigabytes(_ bytes: UInt64) -> String {
    String(format: "%.1f GB", Double(bytes) / Double(MemoryBudget.gib))
  }
}
