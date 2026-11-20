import AgentGateCore
import AppKit
import SwiftUI

@main
struct AgentGateStudioApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @State private var app = AppModel()

  var body: some Scene {
    WindowGroup("AGENTGATE Studio") {
      Shell()
        .environment(app)
        .frame(minWidth: 1080, minHeight: 680)
        .task {
          // Engines left running by a crash or a forced quit are stopped before anything loads.
          EngineRegistry().reapOrphans()
          app.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
          app.stopRuntime()
        }
    }
    .windowStyle(.hiddenTitleBar)
    .commands {
      // The web app's shortcuts, as menu commands so they work from anywhere in the window.
      CommandMenu("Go") {
        Button("Find a Project or View…") { app.paletteOpen = true }.keyboardShortcut("k")
        Divider()
        Button("Workspace") { app.route = .workspace }.keyboardShortcut("1")
        Button("Security & Verification") { app.route = .security }.keyboardShortcut("2")
        Button("Models & Providers") { app.route = .models }.keyboardShortcut("3")
      }
    }
  }
}

/// Run from `swift run`, the process is not an app bundle: make it a regular, focusable app.
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var signalSources: [DispatchSourceSignal] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    // A kill or Ctrl-C stops this app's engines and exits. It does not go through
    // NSApp.terminate, which a sheet or dialog can refuse, leaving the engine running.
    for sig in [SIGTERM, SIGINT] {
      signal(sig, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
      source.setEventHandler {
        EngineRegistry().reapOrphans()
        exit(0)
      }
      source.resume()
      signalSources.append(source)
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
