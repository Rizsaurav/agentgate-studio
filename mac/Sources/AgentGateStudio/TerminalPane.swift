import AgentGateCore
import AppKit
import SwiftTerm
import SwiftUI

/// A real terminal in the project folder: the user's own login shell, full colour and keyboard, like any terminal app.
/// It runs with the user's rights and is separate from the agent, whose commands still ask first and are checked.
struct TerminalPane: NSViewRepresentable {
  let folder: String

  func makeNSView(context: Context) -> LocalProcessTerminalView {
    let view = LocalProcessTerminalView(frame: .zero)
    view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    view.nativeBackgroundColor = NSColor(Theme.bg)
    view.nativeForegroundColor = NSColor(Theme.text)
    view.caretColor = NSColor(Theme.accent)
    view.processDelegate = context.coordinator
    let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? "/bin/zsh"
    var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
    // The app's own test-only settings never reach the user's shell.
    environment.removeAll { $0.hasPrefix("OPENROUTER_API_KEY=") || $0.hasPrefix("AGENTGATE_") }
    view.startProcess(
      executable: shell, args: ["-l"], environment: environment,
      execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: folder)
    return view
  }

  func updateNSView(_ view: LocalProcessTerminalView, context: Context) {}

  static func dismantleNSView(_ view: LocalProcessTerminalView, coordinator: Coordinator) {
    view.terminate()
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {}
  }
}
