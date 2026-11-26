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
      ForEach(StepGroup.group(steps)) { item in
        switch item {
        case .explored(let looks):
          ExploredRow(steps: looks)
        case .single(let step):
          switch step.kind {
          case .text: if !step.text.isEmpty { AnswerText(text: step.text) }
          case .reasoning: if !step.text.isEmpty { ReasoningView(text: step.text) }
          case .tool, .refused: StepCard(step: step, permission: step.id == waiting ? app.pendingPermission : nil)
          }
        }
      }
      if let note = notes(steps) { AnswerText(text: note).foregroundStyle(Theme.danger) }
      // A question the harness asked before its step appeared gets a card of its own.
      if live, waiting == nil, let permission = app.pendingPermission { PermissionCard(permission: permission) }
      if live && app.generating && app.pendingPermission == nil && app.transcript.running == nil {
        WorkingLine(started: app.turnStarted, label: steps.isEmpty ? "Thinking" : "Working")
      }
      if !live, let changes = message.changes, !changes.isEmpty { ChangesCard(changes: changes) }
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

/// Steps as the chat lays them out: runs of finished look-ups (reads, searches) fold into one row, so commands,
/// edits and the answer stand out.
enum StepGroup: Identifiable {
  case single(AgentStep)
  case explored([AgentStep])

  var id: String {
    switch self {
    case .single(let step): step.id
    case .explored(let steps): "explored-" + (steps.first?.id ?? "")
    }
  }

  static let lookups: Set<String> = ["read", "glob", "grep", "list", "lsp"]

  static func isLookup(_ step: AgentStep) -> Bool {
    step.kind == .tool && step.status == .done && lookups.contains(step.tool)
  }

  static func group(_ steps: [AgentStep]) -> [StepGroup] {
    var items: [StepGroup] = []
    var run: [AgentStep] = []
    func flush() {
      if run.count >= 2 { items.append(.explored(run)) } else { items += run.map(StepGroup.single) }
      run = []
    }
    // The to-do list is one living checklist: each update replaces the last, so only the newest is shown.
    let lastTodo = steps.lastIndex { $0.tool == "todowrite" && !($0.todos ?? []).isEmpty }
    for (index, step) in steps.enumerated() {
      if step.tool == "todowrite", let lastTodo, index != lastTodo, step.status == .done { continue }
      if isLookup(step) {
        run.append(step)
      } else if (step.kind == .text || step.kind == .reasoning) && step.text.isEmpty {
        continue
      } else {
        flush()
        items.append(.single(step))
      }
    }
    flush()
    return items
  }
}

/// A run of look-ups in one line: how many files were read and searches made, open on a click.
private struct ExploredRow: View {
  let steps: [AgentStep]
  @State private var open = false

  /// What was looked at, each name once, in order.
  private var names: [String] {
    var seen: Set<String> = []
    return steps.map { ($0.text as NSString).lastPathComponent }.filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  private var summary: String {
    let reads = steps.filter { $0.tool == "read" }.count
    let searches = steps.count - reads
    var parts: [String] = []
    if reads > 0 { parts.append(plural(reads, "file") + " read") }
    if searches > 0 { parts.append(searches == 1 ? "1 search" : "\(searches) searches") }
    return parts.joined(separator: ", ")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button { open.toggle() } label: {
        HStack(spacing: 10) {
          Image(systemName: "binoculars").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.success)
            .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 7).fill(Theme.success.opacity(0.12)))
          Text("Explored").font(.system(size: 13, weight: .semibold))
          Text(summary).font(.system(size: 12)).foregroundStyle(Theme.muted)
          Text(names.prefix(4).joined(separator: "  "))
            .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.muted.opacity(0.8)).lineLimit(1)
            .truncationMode(.tail)
          Spacer(minLength: 8)
          Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.success.opacity(0.3)))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(open ? "Hide the look-ups" : "Show each look-up")
      if open {
        ForEach(steps) { StepCard(step: $0) }.padding(.leading, 18)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Explored: \(summary)")
  }
}

/// An answer drawn as blocks: headings, paragraphs with inline Markdown, code, and the app's control lines as labels.
private struct AnswerText: View {
  let text: String
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(AnswerBlock.parse(text).enumerated()), id: \.offset) { _, block in
        switch block {
        case .heading(let level, let title):
          Text(LocalizedStringKey(title)).font(.system(size: level <= 2 ? 16 : 14.5, weight: .semibold))
            .padding(.top, 4)
        case .paragraph(let body):
          Text(LocalizedStringKey(body)).lineSpacing(3)
        case .code(let code):
          Text(code).font(.system(size: 12.5, design: .monospaced))
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg))
        case .marker(let kind, let detail):
          MarkerLabel(kind: kind, detail: detail)
        }
      }
    }
    .textSelection(.enabled)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A control line the agent wrote for the app, shown as what it means.
private struct MarkerLabel: View {
  let kind: AnswerBlock.Marker
  let detail: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Label(title, systemImage: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
        .padding(.horizontal, 9).padding(.vertical, 4).background(Capsule().fill(color.opacity(0.14)))
      if !detail.isEmpty { Text(detail).font(.system(size: 13)).foregroundStyle(Theme.muted) }
    }
  }

  private var title: String {
    switch kind {
    case .planReady: "Plan ready"
    case .goalComplete: "Goal reported done"
    case .goalBlocked: "Needs you"
    case .goalContinue: "Next round"
    }
  }

  private var symbol: String {
    switch kind {
    case .planReady: "list.bullet.clipboard"
    case .goalComplete: "checkmark.seal"
    case .goalBlocked: "hand.raised"
    case .goalContinue: "arrow.forward.circle"
    }
  }

  private var color: Color {
    switch kind {
    case .planReady, .goalContinue: Theme.accent
    case .goalComplete: Theme.success
    case .goalBlocked: Theme.warning
    }
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
    return ["bash", "edit", "write", "patch", "multiedit", "todowrite"].contains(step.tool)
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
    if let todos = step.todos, !todos.isEmpty {
      return "\(todos.filter(\.isDone).count) of \(todos.count) done"
    }
    if let purpose = step.purpose, !purpose.isEmpty, step.tool == "bash" { return purpose }
    return step.text.replacingOccurrences(of: "\n", with: " ")
  }

  private var verb: String {
    let running = step.status == .running || step.status == .pending
    if step.output == AgentStep.deniedByUser { return step.tool == "bash" ? "You denied the command" : "You denied the \(step.tool)" }
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
    case "todowrite", "todoread": return "To-do list"
    case "task": return running ? "Helper agent working" : step.status == .failed ? "Helper agent failed" : "Helper agent finished"
    case "skill": return running ? "Loading skill" : "Loaded skill"
    case "websearch": return running ? "Searching the web" : "Searched the web"
    case "lsp": return running ? "Looking up code" : "Looked up code"
    default:
      // MCP tools are named <server>_<tool>.
      if let split = step.tool.firstIndex(of: "_") {
        return "\(step.tool[..<split]): \(step.tool[step.tool.index(after: split)...].replacingOccurrences(of: "_", with: " "))"
      }
      return step.tool
    }
  }

  private var deniedByUser: Bool { step.output == AgentStep.deniedByUser }

  private var icon: String {
    if deniedByUser { return "hand.thumbsdown" }
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
    case "skill": return "book"
    case "websearch": return "globe.badge.chevron.backward"
    case "lsp": return "arrow.triangle.branch"
    default: return step.tool.contains("_") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
    }
  }

  private var border: Color {
    if permission != nil { return Theme.warning }
    if deniedByUser { return Theme.muted }
    switch step.status {
    case .running, .pending: return Theme.accent
    case .done: return Theme.success
    case .failed, .refused: return Theme.danger
    }
  }

  // MARK: Body

  private var hasBody: Bool {
    if preparing { return false }
    return permission != nil || step.tool == "bash" || step.diff != nil || !step.output.isEmpty || step.error != nil
      || step.kind == .refused || !(step.todos ?? []).isEmpty
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
      } else if let todos = step.todos, !todos.isEmpty {
        TodoList(items: todos)
      } else if let diff = step.diff {
        DiffView(diff: diff)
      } else if step.kind == .refused {
        Label {
          Text(step.output).font(.system(size: 12.5)).textSelection(.enabled)
        } icon: {
          Image(systemName: deniedByUser ? "hand.raised" : "shield.lefthalf.filled")
            .foregroundStyle(deniedByUser ? Theme.muted : Theme.danger)
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

/// What the turn changed in the project, measured against the moment before it started.
struct ChangesCard: View {
  let changes: [FileChange]
  @State private var expanded = false

  private var added: Int { changes.reduce(0) { $0 + $1.added } }
  private var removed: Int { changes.reduce(0) { $0 + $1.removed } }
  private var shown: [FileChange] { expanded ? changes : Array(changes.prefix(5)) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "doc.on.doc").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
        Text("Changed \(plural(changes.count, "file"))").font(.system(size: 13, weight: .semibold))
        Text("+\(added)").foregroundStyle(Theme.success).font(.system(size: 12, weight: .medium, design: .monospaced))
        Text("−\(removed)").foregroundStyle(Theme.danger).font(.system(size: 12, weight: .medium, design: .monospaced))
        Spacer()
        Text("this turn").font(.system(size: 11)).foregroundStyle(Theme.muted)
      }
      .padding(.horizontal, 12).padding(.vertical, 10)
      Divider().overlay(Theme.line)
      VStack(alignment: .leading, spacing: 6) {
        ForEach(shown) { change in
          HStack(spacing: 8) {
            Text(badge(change.kind)).font(.system(size: 10, weight: .bold, design: .monospaced))
              .foregroundStyle(color(change.kind)).frame(width: 14)
            Text(change.path).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text("+\(change.added)").foregroundStyle(Theme.success)
            Text("−\(change.removed)").foregroundStyle(Theme.danger)
          }
          .font(.system(size: 11.5, design: .monospaced))
        }
        if changes.count > 5 {
          Button(expanded ? "Show fewer" : "Show all \(changes.count)") { expanded.toggle() }.buttonStyle(LinkButtonStyle())
        }
      }
      .padding(12)
    }
    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent.opacity(0.3)))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Changed \(plural(changes.count, "file")), \(added) lines added, \(removed) removed")
  }

  private func badge(_ kind: FileChange.Kind) -> String {
    switch kind {
    case .added: "A"
    case .modified: "M"
    case .deleted: "D"
    }
  }

  private func color(_ kind: FileChange.Kind) -> Color {
    switch kind {
    case .added: Theme.success
    case .modified: Theme.warning
    case .deleted: Theme.danger
    }
  }
}

/// The agent's to-do list as a checklist: done, in progress, and still to do.
struct TodoList: View {
  let items: [TodoItem]

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in
        HStack(alignment: .firstTextBaseline, spacing: 9) {
          Image(systemName: symbol(item)).font(.system(size: 12)).foregroundStyle(color(item))
          Text(item.content).font(.system(size: 13)).strikethrough(item.status == "cancelled")
            .foregroundStyle(item.isDone || item.status == "cancelled" ? Theme.muted : Theme.text)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func symbol(_ item: TodoItem) -> String {
    switch item.status {
    case "completed": "checkmark.circle.fill"
    case "in_progress": "circle.dotted.circle"
    case "cancelled": "xmark.circle"
    default: "circle"
    }
  }

  private func color(_ item: TodoItem) -> Color {
    switch item.status {
    case "completed": Theme.success
    case "in_progress": Theme.accent
    default: Theme.muted
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
