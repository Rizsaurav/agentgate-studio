import AgentGateCore
import AppKit
import SwiftUI

/// An agent answer as it happened: reasoning, every command with its output, every edit with its
/// diff, refusals with their reason, and the answer text, in order. While the turn runs it updates
/// live and shows the question waiting for the user in place.
struct AgentTurnView: View {
  @Environment(AppModel.self) private var app
  let message: ChatMessage
  /// This is the turn in progress.
  let live: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("AGENT").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.accent)
      let steps = message.steps ?? []
      if steps.isEmpty && !message.content.isEmpty {
        // Plain chat, and answers saved before steps were kept.
        AnswerText(text: message.content)
      }
      let waiting = waitingStep(steps)
      ForEach(steps) { step in
        switch step.kind {
        case .text: if !step.text.isEmpty { AnswerText(text: step.text) }
        case .reasoning: if !step.text.isEmpty { ReasoningView(text: step.text) }
        case .tool, .refused: StepCard(step: step, permission: step.id == waiting ? app.pendingPermission : nil)
        }
      }
      if let note = notes(steps) { AnswerText(text: note).foregroundStyle(Theme.danger) }
      // A question the harness asked before its step appeared gets a card of its own.
      if live, waiting == nil, let permission = app.pendingPermission { PermissionCard(permission: permission) }
      if live && app.generating && app.pendingPermission == nil && app.transcript.running == nil {
        WorkingLine(started: app.turnStarted, label: steps.isEmpty ? "Thinking" : "Working")
      }
      if !live, let usage = message.usage { UsageLine(steps: steps, usage: usage) }
    }
    .font(.system(size: 14))
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// The step the pending question is about, matched by the harness's call id.
  private func waitingStep(_ steps: [AgentStep]) -> String? {
    guard live, let permission = app.pendingPermission else { return nil }
    return app.transcript.waitingStep(callID: permission.callID)
  }

  /// What the app added under the answer (errors, stops): the saved text beyond the answer parts.
  private func notes(_ steps: [AgentStep]) -> String? {
    guard !steps.isEmpty else { return nil }
    let answer = steps.filter { $0.kind == .text }.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
    guard message.content.count > answer.count, message.content.hasPrefix(answer) else { return nil }
    let rest = message.content.dropFirst(answer.count).trimmingCharacters(in: .whitespacesAndNewlines)
    return rest.isEmpty ? nil : rest
  }
}

private struct AnswerText: View {
  let text: String
  var body: some View {
    Text(LocalizedStringKey(text)).textSelection(.enabled).lineSpacing(3)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The model's reasoning: folded to its first lines, open on a click.
private struct ReasoningView: View {
  let text: String
  @State private var open = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button { open.toggle() } label: {
        HStack(spacing: 6) {
          Image(systemName: "brain").font(.system(size: 11))
          Text("Reasoning").font(.system(size: 12, weight: .medium))
          Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9))
        }
        .foregroundStyle(Theme.muted).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      Text(text).font(.system(size: 12.5)).italic().foregroundStyle(Theme.muted)
        .lineLimit(open ? nil : 2).textSelection(.enabled)
    }
    .padding(.leading, 10)
    .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 2) }
  }
}

/// One tool call: what it is, its state with a live clock, and everything it produced.
struct StepCard: View {
  let step: AgentStep
  /// The question waiting for the user about this step, if any.
  var permission: AgentEvent.Permission?
  @State private var expanded: Bool?

  private var isOpen: Bool { permission != nil || (expanded ?? Self.opensByDefault(step)) }
  /// The model is still writing the call: nothing to show of it yet.
  private var preparing: Bool { step.status == .pending && step.text.isEmpty }

  /// Commands, edits, failures and refusals are open; reads and searches are one line until clicked.
  static func opensByDefault(_ step: AgentStep) -> Bool {
    if step.status != .done { return true }
    return ["bash", "edit", "write", "patch", "multiedit"].contains(step.tool)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      if isOpen, hasBody {
        Divider().overlay(Theme.line)
        content.padding(12)
      }
    }
    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(border.opacity(0.55)))
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(verb) \(step.text)")
  }

  // MARK: Header

  private var header: some View {
    Button { if hasBody { expanded = !isOpen } } label: {
      HStack(alignment: .center, spacing: 10) {
        Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(border)
          .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 7).fill(border.opacity(0.12)))
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(verb).font(.system(size: 13, weight: .semibold))
            if let counts = step.diffCounts, counts.added + counts.removed > 0 {
              Text("+\(counts.added)").foregroundStyle(Theme.success)
              Text("−\(counts.removed)").foregroundStyle(Theme.danger)
            }
          }
          .font(.system(size: 12, weight: .medium, design: .monospaced))
          Text(subject).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
            .lineLimit(1).truncationMode(.middle)
        }
        Spacer(minLength: 8)
        if permission != nil {
          Text("waiting for you").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.warning)
          Image(systemName: "hand.raised.fill").font(.system(size: 11.5)).foregroundStyle(Theme.warning)
        } else {
          StepStatus(step: step)
        }
        if hasBody {
          Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.system(size: 10))
            .foregroundStyle(Theme.muted).frame(width: 12)
        }
      }
      .padding(.horizontal, 12).padding(.vertical, 10)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(isOpen ? "Hide details" : "Show details")
  }

  private var subject: String {
    if preparing { return step.tool == "bash" ? "Preparing the command…" : "Preparing…" }
    if let purpose = step.purpose, !purpose.isEmpty, step.tool == "bash" { return purpose }
    return step.text.replacingOccurrences(of: "\n", with: " ")
  }

  private var verb: String {
    let running = step.status == .running || step.status == .pending
    if step.kind == .refused || step.status == .refused {
      return step.tool == "bash" ? "Blocked command" : "Blocked \(step.tool)"
    }
    if permission != nil { return step.tool == "bash" ? "Asks to run a command" : "Asks to \(step.tool)" }
    if preparing { return "Preparing \(step.tool)" }
    switch step.tool {
    case "bash":
      if preparing { return "Preparing command" }
      if running { return "Running command" }
      return step.status == .failed ? "Command failed" : "Ran command"
    case "edit", "multiedit", "patch": return running ? "Editing file" : step.status == .failed ? "Edit failed" : "Edited file"
    case "write": return running ? "Writing file" : step.status == .failed ? "Write failed" : "Wrote file"
    case "read": return running ? "Reading" : "Read"
    case "grep": return running ? "Searching code" : "Searched code"
    case "glob": return running ? "Finding files" : "Found files"
    case "list": return running ? "Listing folder" : "Listed folder"
    case "webfetch": return running ? "Fetching" : "Fetched"
    case "todowrite", "todoread": return "Updated the plan"
    case "task": return running ? "Running a helper agent" : "Helper agent finished"
    default: return step.tool
    }
  }

  private var icon: String {
    if step.kind == .refused { return "hand.raised.fill" }
    switch step.tool {
    case "bash": return "terminal"
    case "edit", "multiedit", "patch": return "pencil"
    case "write": return "doc.badge.plus"
    case "read": return "doc.text"
    case "grep": return "text.magnifyingglass"
    case "glob": return "magnifyingglass"
    case "list": return "folder"
    case "webfetch": return "globe"
    case "todowrite", "todoread": return "checklist"
    case "task": return "person.2"
    default: return "wrench.and.screwdriver"
    }
  }

  private var border: Color {
    if permission != nil { return Theme.warning }
    switch step.status {
    case .running, .pending: return Theme.accent
    case .done: return Theme.success
    case .failed, .refused: return Theme.danger
    }
  }

  // MARK: Body

  private var hasBody: Bool {
    if preparing { return false }
    return permission != nil || step.tool == "bash" || step.diff != nil || !step.output.isEmpty || step.error != nil || step.kind == .refused
  }

  @ViewBuilder private var content: some View {
    VStack(alignment: .leading, spacing: 10) {
      if step.tool == "bash" {
        if let purpose = step.purpose, !purpose.isEmpty {
          Text(purpose).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        TerminalOutput(
          command: step.text, output: step.output, running: step.status == .running && permission == nil,
          exitCode: step.exitCode)
      } else if let diff = step.diff {
        DiffView(diff: diff)
      } else if step.kind == .refused {
        Label {
          Text(step.output).font(.system(size: 12.5)).textSelection(.enabled)
        } icon: {
          Image(systemName: "shield.lefthalf.filled").foregroundStyle(Theme.danger)
        }
        Text(step.text).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted).textSelection(.enabled)
      } else if !step.output.isEmpty {
        OutputBox(text: step.output, follow: step.status == .running, limitHeight: 220)
      }
      if let error = step.error, !error.isEmpty { ErrorView(error: error) }
      if step.truncated {
        Text("Earlier output was cut; the end is shown.").font(.system(size: 11)).foregroundStyle(Theme.muted)
      }
      if let permission { ApprovalBar(permission: permission) }
    }
  }
}

/// The question about a step, in plain words, with the choice. Destructive actions say so.
private struct ApprovalBar: View {
  @Environment(AppModel.self) private var app
  let permission: AgentEvent.Permission

  var body: some View {
    let classification = PermissionClassifier.classify(ActionRequest(tool: permission.tool, detail: permission.detail))
    VStack(alignment: .leading, spacing: 8) {
      Text(classification.summary).font(.system(size: 13))
      if classification.destructive {
        Label("This deletes files or history and cannot be undone.", systemImage: "exclamationmark.triangle.fill")
          .font(.system(size: 12)).foregroundStyle(Theme.danger)
      }
      HStack {
        Text("Nothing runs until you answer.").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
        Spacer()
        Button("Deny") { app.answerPermission(allow: false) }
        Button("Allow once") { app.answerPermission(allow: true) }.buttonStyle(.borderedProminent)
      }
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.warning.opacity(0.07)))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.warning.opacity(0.45)))
  }
}

/// Why a step failed, in plain words. The harness's own message, which can be long, is one click away.
private struct ErrorView: View {
  let error: String
  @State private var showRaw = false

  var body: some View {
    let plain = Self.plain(error)
    VStack(alignment: .leading, spacing: 6) {
      Label(plain ?? error, systemImage: "exclamationmark.triangle.fill")
        .font(.system(size: 12.5)).foregroundStyle(Theme.danger).textSelection(.enabled)
      if plain != nil {
        Button(showRaw ? "Hide the harness's message" : "Show the harness's message") { showRaw.toggle() }
          .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
        if showRaw {
          Text(error).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.muted).textSelection(.enabled)
        }
      }
    }
  }

  /// A sentence for the harness's known refusals; nil when the message is already plain.
  static func plain(_ error: String) -> String? {
    if error.contains("prevents you from using this specific tool call") {
      return error.contains("external_directory")
        ? "The harness refused it: the path is outside the project folder."
        : "The harness refused it under its own rules."
    }
    if error.hasPrefix("The user rejected permission to use this specific tool call with the following feedback:") {
      return "Refused before it ran. The agent was told why."
    }
    if error == "The user rejected permission to use this specific tool call." {
      return "Not run: it was denied, or the harness cancelled it when another call was refused."
    }
    return nil
  }
}

/// The right side of a step header: a spinner and live clock while it runs, then how it ended.
private struct StepStatus: View {
  let step: AgentStep

  var body: some View {
    HStack(spacing: 6) {
      switch step.status {
      case .pending:
        ProgressView().controlSize(.mini)
        Text("starting").foregroundStyle(Theme.muted)
      case .running:
        ProgressView().controlSize(.mini)
        if let started = step.started {
          TimelineView(.periodic(from: .now, by: 0.1)) { context in
            Text(seconds(context.date.timeIntervalSince(started))).monospacedDigit().foregroundStyle(Theme.accent)
          }
        }
      case .done:
        if let code = step.exitCode { Text("exit \(code)").foregroundStyle(Theme.muted) }
        if let duration = step.duration { Text(seconds(duration)).monospacedDigit().foregroundStyle(Theme.muted) }
        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
      case .failed:
        if let code = step.exitCode { Text("exit \(code)").foregroundStyle(Theme.danger) }
        if let duration = step.duration { Text(seconds(duration)).monospacedDigit().foregroundStyle(Theme.muted) }
        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger)
      case .refused:
        Text("blocked").foregroundStyle(Theme.danger)
        Image(systemName: "hand.raised.fill").foregroundStyle(Theme.danger)
      }
    }
    .font(.system(size: 11.5, weight: .medium))
  }
}

func seconds(_ value: TimeInterval) -> String {
  value < 60 ? String(format: "%.1fs", max(0, value)) : String(format: "%dm %02ds", Int(value) / 60, Int(value) % 60)
}

/// A command and what it printed, like a terminal: the prompt line, the output as it arrives, and the
/// exit status once it ends.
private struct TerminalOutput: View {
  let command: String
  let output: String
  let running: Bool
  let exitCode: Int?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 8) {
        Text("$").foregroundStyle(Theme.accent)
        Text(command).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        CopyButton(text: command, help: "Copy the command")
      }
      .font(.system(size: 12.5, weight: .medium, design: .monospaced))
      .padding(10)
      if !output.isEmpty || running {
        Divider().overlay(Theme.line)
        OutputBox(
          text: output.isEmpty ? "Waiting for output…" : output, follow: running, limitHeight: 300,
          dimmed: output.isEmpty, copyable: !output.isEmpty, framed: false)
      }
      if let exitCode {
        Divider().overlay(Theme.line)
        Text(exitCode == 0 ? "Exited with 0" : "Exited with \(exitCode)")
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(exitCode == 0 ? Theme.success : Theme.danger)
          .padding(.horizontal, 10).padding(.vertical, 6)
      }
    }
    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
  }
}

/// Monospaced output in a scroll box. While the step runs it follows the newest line.
private struct OutputBox: View {
  let text: String
  let follow: Bool
  let limitHeight: CGFloat
  var dimmed = false
  var copyable = true
  var framed = true

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        Text(text)
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(dimmed ? Theme.muted : Theme.text.opacity(0.92))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
        Color.clear.frame(height: 1).id("end")
      }
      .frame(maxHeight: limitHeight)
      .fixedSize(horizontal: false, vertical: true)
      .onChange(of: text) { if follow { proxy.scrollTo("end", anchor: .bottom) } }
      .onAppear { if follow { proxy.scrollTo("end", anchor: .bottom) } }
    }
    .overlay(alignment: .topTrailing) {
      if copyable { CopyButton(text: text, help: "Copy the output").padding(6) }
    }
    .background { if framed { RoundedRectangle(cornerRadius: 8).fill(Theme.bg) } }
    .overlay { if framed { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line) } }
  }
}

/// A unified diff with added lines in green and removed lines in red. File headers are left out.
private struct DiffView: View {
  let diff: String

  var body: some View {
    ScrollView([.vertical]) {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
          Text(line.isEmpty ? " " : line)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(color(line))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 1)
            .background(background(line))
        }
      }
      .textSelection(.enabled)
      .padding(.vertical, 6)
    }
    .frame(maxHeight: 320)
    .fixedSize(horizontal: false, vertical: true)
    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private var lines: [String] {
    diff.components(separatedBy: "\n").filter {
      !($0.hasPrefix("Index:") || $0.hasPrefix("====") || $0.hasPrefix("---") || $0.hasPrefix("+++"))
    }
    .reversed().drop { $0.isEmpty }.reversed()
  }

  private func color(_ line: String) -> Color {
    if line.hasPrefix("+") { return Theme.success }
    if line.hasPrefix("-") { return Theme.danger }
    if line.hasPrefix("@@") { return Theme.accent }
    return Theme.muted
  }

  private func background(_ line: String) -> Color {
    if line.hasPrefix("+") { return Theme.success.opacity(0.10) }
    if line.hasPrefix("-") { return Theme.danger.opacity(0.10) }
    return .clear
  }
}

private struct CopyButton: View {
  let text: String
  let help: String
  @State private var copied = false

  var body: some View {
    Button {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      copied = true
      Task {
        try? await Task.sleep(for: .seconds(1.5))
        copied = false
      }
    } label: {
      Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10.5))
        .foregroundStyle(copied ? Theme.success : Theme.muted)
        .frame(width: 22, height: 22)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface.opacity(0.9)))
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(help)
  }
}

/// The agent is waiting for the user: what it wants to do, in plain words, and the choice.
private struct PermissionCard: View {
  let permission: AgentEvent.Permission

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: "hand.raised").foregroundStyle(Theme.warning)
        Text("The agent is waiting for you").font(.system(size: 13, weight: .semibold))
        Spacer()
        Text(permission.tool).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Theme.muted)
      }
      Text(permission.detail).font(.system(size: 12.5, design: .monospaced)).textSelection(.enabled)
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg))
      ApprovalBar(permission: permission)
    }
    .padding(14)
    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.warning.opacity(0.55)))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("The agent is waiting for you")
  }
}

/// Shown while the model is thinking between steps, with the turn's clock.
private struct WorkingLine: View {
  let started: Date?
  let label: String

  var body: some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text("\(label)…").foregroundStyle(Theme.muted)
      if let started {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
          Text(seconds(context.date.timeIntervalSince(started))).monospacedDigit().foregroundStyle(Theme.muted)
        }
      }
    }
    .font(.system(size: 13))
  }
}

/// Under a finished answer: how many steps, how long, and what the model used.
private struct UsageLine: View {
  let steps: [AgentStep]
  let usage: TurnUsage

  var body: some View {
    let tools = steps.filter { $0.kind == .tool || $0.kind == .refused }
    let failed = tools.filter { $0.status == .failed || $0.status == .refused }.count
    var parts = [plural(tools.count, "step"), seconds(usage.seconds)]
    if failed > 0 { parts.insert("\(failed) failed or blocked", at: 1) }
    if usage.tokensIn > 0 { parts.append("\(compact(usage.tokensIn)) tokens in · \(compact(usage.tokensOut)) out") }
    return Text(parts.joined(separator: "  ·  ")).font(.system(size: 11)).foregroundStyle(Theme.muted)
  }

  private func compact(_ value: Int) -> String {
    value >= 1000 ? String(format: "%.1fk", Double(value) / 1000) : "\(value)"
  }
}
