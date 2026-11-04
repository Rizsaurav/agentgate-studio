import AgentGateCore
import AppKit
import SwiftUI

@main
struct AgentGateStudioApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @State private var app = AppModel()

  var body: some Scene {
    WindowGroup("AGENTGATE Studio") {
      ContentView()
        .environment(app)
        .frame(minWidth: 820, minHeight: 560)
        .task {
          // Engines left running by a crash or a forced quit are stopped before anything loads.
          EngineRegistry().reapOrphans()
          app.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
          app.stopRuntime()
        }
    }
    .windowToolbarStyle(.unified)
  }
}

/// Run from `swift run`, the process is not an app bundle: make it a regular, focusable app.
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var signalSources: [DispatchSourceSignal] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    // A kill or Ctrl-C ends the app through the normal quit path, which stops the engine.
    for sig in [SIGTERM, SIGINT] {
      signal(sig, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
      source.setEventHandler { NSApp.terminate(nil) }
      source.resume()
      signalSources.append(source)
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    VStack(spacing: 0) {
      if let error = app.loadError {
        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).padding()
      }
      ChatView()
      InstallStrip()
    }
    .toolbar {
      ToolbarItem(placement: .navigation) { ModelPicker() }
      ToolbarItem(placement: .status) {
        if let profile = app.profile {
          Label(profile.summary, systemImage: "cpu").labelStyle(.titleAndIcon).foregroundStyle(.secondary)
            .font(.callout)
        }
      }
    }
  }
}
