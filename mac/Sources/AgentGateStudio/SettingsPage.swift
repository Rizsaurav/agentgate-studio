import AgentGateCore
import SwiftUI

/// Settings that are not about keys (#113). Each says in one sentence what it changes. They are kept in
/// this Mac's preferences for the app, never in a project folder, and none can turn off the command and
/// file rules or the questions they ask.
struct SettingsPage: View {
  @Environment(AppModel.self) private var app
  @State private var modelsSize: UInt64?
  @State private var partials = 0
  @State private var storageMessage: String?
  @State private var confirmClear = false

  var body: some View {
    @Bindable var bound = app
    PageScroll {
      VStack(alignment: .leading, spacing: 30) {
        Button { app.route = .profile } label: { Text("← Profile").font(.system(size: 13)) }
          .buttonStyle(.plain).foregroundStyle(Theme.muted)
        Text("Settings").font(.system(size: 30, weight: .bold)).tracking(-0.6)

        section("Autonomy") {
          Picker("Autonomy", selection: $bound.autonomy) {
            ForEach(Autonomy.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          .pickerStyle(.segmented).frame(width: 320).labelsHidden()
          note("How much the repair agent may do on its own during an install. " + app.autonomy.summary)
          HStack(spacing: 16) {
            Stepper("Ask before re-downloading over \(app.askAboveGB) GB", value: $bound.askAboveGB, in: 1...200)
            Stepper("Wait \(app.approvalMinutes) min for an answer", value: $bound.approvalMinutes, in: 1...60)
          }
          .font(.system(size: 12))
          note("An unanswered question counts as no: nothing is done and the install pauses.")
        }

        section("Defaults") {
          Picker("Model for new chats", selection: $bound.defaultModelId) {
            Text("The loaded model").tag(String?.none)
            ForEach(app.installed) { Text("\($0.name) · \($0.quant.rawValue)").tag(Optional($0.id)) }
          }
          .frame(maxWidth: 380)
          note("The model a new chat starts with; you can still pick another in the chat.")
          HStack {
            Text((app.projectsRoot.path as NSString).abbreviatingWithTildeInPath).font(.system(size: 12, design: .monospaced))
            Spacer()
            Button("Choose…") { app.chooseProjectsFolder() }.controlSize(.small)
            if app.projectsFolder != nil { Button("Use default") { app.projectsFolder = nil }.controlSize(.small) }
          }
          note("Where new projects are created. Projects you already have stay where they are.")
        }

        section("Storage") {
          row("Models", value: modelsSize.map(ModelPlanner.gb) ?? "…")
          note("Installed models, in \((ModelStore().root.path as NSString).abbreviatingWithTildeInPath). Remove one on the Models page.")
          HStack {
            Text(partials == 0 ? "No partial downloads" : "\(plural(partials, "partial download"))").font(.system(size: 13))
            Spacer()
            Button("Delete partial downloads") {
              storageMessage = app.removePartialDownloads()
              refresh()
            }
            .controlSize(.small).disabled(partials == 0 || app.installing != nil)
          }
          note("Frees space held by downloads that stopped. A stopped download then starts from the beginning.")
          HStack {
            Text("Repair audit and security log").font(.system(size: 13))
            Spacer()
            Button("Clear…") { confirmClear = true }.controlSize(.small)
              .confirmationDialog("Clear the repair audit and the security log?", isPresented: $confirmClear) {
                Button("Clear both logs", role: .destructive) { storageMessage = app.clearLogs() }
              }
          }
          note("Removes the record of past repairs and security decisions. The rules keep applying.")
          if let storageMessage { Text(storageMessage).font(.system(size: 12)) }
        }

        section("Privacy") {
          Toggle("Keep the model advisor on this Mac", isOn: $bound.advisorLocalOnly)
          note("When on, what you type into the advisor is read by fixed rules here and never sent to the agent's provider.")
          note("Sent to the agent's provider (\(app.activeAgent.name)) when the agent is on: install failure reports with keys and private paths removed, and, unless the switch above is on, advisor task descriptions. Project files and chats are not sent to it.")
        }

        section("Versions") {
          row("Model engine", value: tag(LlamaRuntime.binaryDirectory()).map { "llama.cpp \($0)" } ?? "not found")
          row("Agent harness", value: tag(AgentServer.binaryDirectory()).map { "OpenCode \($0)" } ?? "not found")
          row("Model catalog", value: app.catalog.map { "\(plural($0.models.count, "model")), version \($0.version)" } ?? "…")
          note("What is built into this copy of the app.")
        }

        note("Appearance follows the system. The command and file rules, and the questions they ask, are not settings: they always apply.")
      }
      .frame(maxWidth: 680, alignment: .leading)
    }
    .onAppear(perform: refresh)
  }

  private func refresh() {
    let root = ModelStore().root
    partials = Storage.partialDownloads(in: root).count
    Task.detached {
      let size = Storage.size(of: root)
      await MainActor.run { modelsSize = size }
    }
  }

  private func tag(_ folder: URL?) -> String? {
    folder.flatMap { try? String(contentsOf: $0.appendingPathComponent(".tag"), encoding: .utf8) }?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.system(size: 16, weight: .semibold))
      Card(padding: 16) { VStack(alignment: .leading, spacing: 10) { content() } }
    }
  }

  private func row(_ label: String, value: String) -> some View {
    HStack {
      Text(label).font(.system(size: 13))
      Spacer()
      Text(value).font(.system(size: 13)).foregroundStyle(Theme.muted)
    }
  }

  private func note(_ text: String) -> some View {
    Text(text).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
  }
}
