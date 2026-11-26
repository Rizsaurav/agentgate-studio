import AgentGateCore
import SwiftUI

/// The goal a session works toward: objective, phase, rounds used, and what the user can do about it.
struct GoalBanner: View {
  @Environment(AppModel.self) private var app
  let sessionId: UUID
  let goal: Goal
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Image(systemName: "scope").font(.system(size: 13, weight: .semibold)).foregroundStyle(tone)
        Text("GOAL").font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.muted)
        StatusPill(text: phaseText, tone: pillTone)
        Spacer()
        Text("Round \(goal.roundsStarted) of \(goal.maxRounds)").font(.system(size: 12)).monospacedDigit()
          .foregroundStyle(Theme.muted)
        actions
      }
      Text(goal.objective).font(.system(size: 13)).lineLimit(expanded ? nil : 2)
        .textSelection(.enabled)
        .onTapGesture { expanded.toggle() }
        .help(expanded ? "" : "Click to read the whole objective")
      RoundTrack(goal: goal, running: running)
      if let detail {
        Text(detail).font(.system(size: 12)).foregroundStyle(goal.phase == .blocked ? Theme.warning : Theme.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(14)
    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tone.opacity(0.35)))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Goal, \(phaseText), round \(goal.roundsStarted) of \(goal.maxRounds)")
  }

  private var running: Bool { app.generating && goal.phase == .active }

  @ViewBuilder private var actions: some View {
    switch goal.phase {
    case .active:
      Button("Pause") { app.pauseGoal(in: sessionId) }.controlSize(.small)
    case .paused:
      Button("Resume") { app.resumeGoal(in: sessionId) }.controlSize(.small).disabled(app.generating)
    case .blocked:
      if goal.roundsLeft == 0 {
        Button("Add 4 rounds") { app.resumeGoal(in: sessionId, extraRounds: 4) }.controlSize(.small)
          .disabled(app.generating)
      } else {
        Button("Try again") { app.resumeGoal(in: sessionId) }.controlSize(.small).disabled(app.generating)
      }
    case .complete:
      EmptyView()
    }
    if goal.phase != .active {
      Button { app.clearGoal(in: sessionId) } label: { Image(systemName: "xmark") }
        .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Remove the goal from this chat")
    }
  }

  private var phaseText: String {
    switch goal.phase {
    case .active: running ? "Working" : "Starting next round"
    case .paused: "Paused"
    case .blocked: "Needs you"
    case .complete: "Complete"
    }
  }

  private var pillTone: StatusPill.Tone {
    switch goal.phase {
    case .active: .pending
    case .paused: .neutral
    case .blocked: .bad
    case .complete: .ok
    }
  }

  private var tone: Color {
    switch goal.phase {
    case .active: Theme.accent
    case .paused: Theme.muted
    case .blocked: Theme.warning
    case .complete: Theme.success
    }
  }

  private var detail: String? {
    switch goal.phase {
    case .blocked: goal.blocker
    case .complete:
      (goal.note.map { "Done: \($0)" } ?? "Done.") + (goal.check.map { " Verified: `\($0)` passed." } ?? "")
    default:
      goal.verifying ? "The agent reports it done; next round runs `\(goal.check ?? "")` to confirm." : nil
        ?? goal.note.map { "Next: \($0)" }
        ?? (goal.filesChanged > 0 ? "\(plural(goal.filesChanged, "file")) changed so far." : nil)
    }
  }
}

/// One segment per round: used, running, and left.
private struct RoundTrack: View {
  let goal: Goal
  let running: Bool

  var body: some View {
    HStack(spacing: 3) {
      ForEach(1...max(goal.maxRounds, 1), id: \.self) { round in
        Capsule().fill(color(round)).frame(height: 5)
          .overlay {
            if running && round == goal.roundsStarted {
              TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                Capsule().fill(Theme.accent.opacity(0.35 + 0.65 * abs(sin(phase * .pi))))
              }
            }
          }
      }
    }
    .accessibilityHidden(true)
  }

  private func color(_ round: Int) -> Color {
    if round < goal.roundsStarted || (round == goal.roundsStarted && !running) {
      return goal.phase == .complete ? Theme.success : Theme.accent.opacity(0.85)
    }
    if round == goal.roundsStarted { return Theme.accent }
    return Theme.text.opacity(0.08)
  }
}

/// The repository at a glance: languages, size, branch, last commit and the check the agent will run.
struct RepoOverview: View {
  let summary: RepoSummary?
  let folder: String
  /// The folder did not answer: macOS is probably waiting for the user to allow access.
  var blocked = false
  var retry: () -> Void = {}

  var body: some View {
    Card(padding: 20) {
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 10) {
          IconTile(symbol: "folder", size: 34)
          VStack(alignment: .leading, spacing: 2) {
            Text((folder as NSString).abbreviatingWithTildeInPath).font(.system(size: 13, weight: .medium))
              .lineLimit(1).truncationMode(.middle)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(blocked ? Theme.warning : Theme.muted)
              .lineLimit(blocked ? 3 : 1).fixedSize(horizontal: false, vertical: true)
          }
          Spacer()
          if summary == nil && !blocked { ProgressView().controlSize(.small) }
          if blocked { Button("Try again", action: retry).controlSize(.small) }
        }
        if let summary {
          if summary.languages.isEmpty {
            Text("No source files found yet.").font(.system(size: 12)).foregroundStyle(Theme.muted)
          } else {
            LanguageBar(languages: summary.languages)
          }
          HStack(spacing: 0) {
            Stat(value: summary.files.formatted(), label: summary.truncated ? "files (first)" : "files")
            Stat(value: summary.lines.formatted(.number.notation(.compactName)), label: "lines of code")
            Stat(value: summary.isGit ? "\(summary.changed)" : "n/a", label: "uncommitted")
          }
          VStack(alignment: .leading, spacing: 8) {
            Fact(symbol: "checkmark.seal", label: "Checks with",
                 value: summary.testCommand ?? "no test command found", mono: summary.testCommand != nil)
            Fact(symbol: "text.book.closed", label: "Instructions",
                 value: summary.instructions.map { "\($0), read at the start of every chat" } ?? "none yet (add an AGENTS.md)",
                 mono: false)
            if let commit = summary.lastCommit {
              Fact(symbol: "clock.arrow.circlepath", label: "Last commit",
                   value: commit + (summary.lastCommitDate.map { "  ·  " + $0.formatted(.relative(presentation: .named)) } ?? ""))
            }
          }
        }
      }
    }
  }

  private var subtitle: String {
    guard let summary else {
      return blocked
        ? "The folder did not answer. macOS may be asking for permission to read it: answer the prompt, then try again."
        : "Reading the repository…"
    }
    var parts: [String] = []
    if let branch = summary.branch { parts.append("on \(branch)") } else if !summary.isGit { parts.append("not a git repository") }
    if let language = summary.primaryLanguage { parts.append(language) }
    return parts.joined(separator: "  ·  ")
  }
}

/// The share of each language, as one bar and a legend, like a code host's language strip.
struct LanguageBar: View {
  let languages: [RepoSummary.Language]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      GeometryReader { geometry in
        HStack(spacing: 2) {
          ForEach(languages) { language in
            Rectangle().fill(LanguageColor.of(language.name))
              .frame(width: max(3, (geometry.size.width - CGFloat(languages.count - 1) * 2) * language.share))
          }
        }
      }
      .frame(height: 8)
      .clipShape(Capsule())
      FlowRow(spacing: 14) {
        ForEach(languages) { language in
          HStack(spacing: 5) {
            Circle().fill(LanguageColor.of(language.name)).frame(width: 8, height: 8)
            Text(language.name).font(.system(size: 12, weight: .medium))
            Text(language.share.formatted(.percent.precision(.fractionLength(language.share < 0.1 ? 1 : 0))))
              .font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit()
          }
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(languages.map { "\($0.name) \(Int(($0.share * 100).rounded())) percent" }.joined(separator: ", "))
  }
}

/// The colours code hosts use for each language, so the bar reads at a glance.
enum LanguageColor {
  static func of(_ name: String) -> Color {
    let hex: UInt32 = switch name {
    case "Swift": 0xF05138
    case "Python": 0x3572A5
    case "TypeScript": 0x3178C6
    case "JavaScript": 0xF1E05A
    case "Go": 0x00ADD8
    case "Rust": 0xDEA584
    case "Java": 0xB07219
    case "Kotlin": 0xA97BFF
    case "C": 0x555555
    case "C++": 0xF34B7D
    case "Objective-C": 0x438EFF
    case "C#": 0x178600
    case "Ruby": 0x701516
    case "PHP": 0x4F5D95
    case "Shell": 0x89E051
    case "HTML": 0xE34C26
    case "CSS": 0x663399
    case "Vue": 0x41B883
    case "Svelte": 0xFF3E00
    case "Dart": 0x00B4AB
    case "SQL": 0xE38C00
    default: 0x6E6F7A
    }
    return Color(hex: hex)
  }
}

private struct Stat: View {
  let value: String
  let label: String
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value).font(.system(size: 20, weight: .semibold)).monospacedDigit()
      Text(label).font(.system(size: 11)).foregroundStyle(Theme.muted)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct Fact: View {
  let symbol: String
  let label: String
  let value: String
  var mono = false
  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Theme.muted).frame(width: 14)
      Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted)
      Text(value).font(.system(size: 12, design: mono ? .monospaced : .default)).lineLimit(1).truncationMode(.tail)
    }
  }
}

/// Starting points for an empty chat. The first one starts a goal; the others send a task.
struct SuggestionChips: View {
  struct Suggestion: Identifiable {
    var id: String { title }
    let symbol: String
    let title: String
    let detail: String
    let isGoal: Bool
  }

  let testCommand: String?
  let disabled: Bool
  let send: (String) -> Void
  let startGoal: (String) -> Void

  private var suggestions: [Suggestion] {
    [
      .init(symbol: "scope", title: "Optimize this repo",
            detail: "Rounds of small, verified fixes until it is done", isGoal: true),
      .init(symbol: "checkmark.seal", title: "Fix the failing tests",
            detail: testCommand.map { "Runs \($0), fixes what fails" } ?? "Finds the tests, fixes what fails", isGoal: false),
      .init(symbol: "map", title: "Explain this codebase",
            detail: "The structure, the entry points, how it fits", isGoal: false),
      .init(symbol: "magnifyingglass", title: "Review uncommitted changes",
            detail: "Bugs and risks in what changed", isGoal: false),
    ]
  }

  var body: some View {
    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
      ForEach(suggestions) { suggestion in
        ChipButton(suggestion: suggestion) {
          if suggestion.isGoal {
            startGoal(Goal.optimize(testCommand: testCommand))
          } else {
            send(task(for: suggestion))
          }
        }
        .disabled(disabled)
      }
    }
    .frame(maxWidth: 560)
  }

  private func task(for suggestion: Suggestion) -> String {
    switch suggestion.title {
    case "Fix the failing tests":
      testCommand.map { "Run `\($0)`. If anything fails, find the cause, fix it, and run the tests again to prove it." }
        ?? "Find how this project runs its tests and run them. If anything fails, find the cause, fix it, and run them again."
    case "Explain this codebase":
      "Explain this codebase: what it does, how it is structured, the main entry points, and how the parts fit together. Read the files; do not change anything."
    default:
      "Review the uncommitted changes (git diff). Point out bugs, risks and anything unclear, with file and line. Do not change anything."
    }
  }
}

private struct ChipButton: View {
  let suggestion: SuggestionChips.Suggestion
  let action: () -> Void
  @State private var hover = false
  @Environment(\.isEnabled) private var enabled

  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: suggestion.symbol).font(.system(size: 14, weight: .medium))
          .foregroundStyle(suggestion.isGoal ? Color(hex: 0x15121F) : Theme.accent)
          .frame(width: 30, height: 30)
          .background(RoundedRectangle(cornerRadius: 8).fill(suggestion.isGoal ? Theme.accent : Theme.accent.opacity(0.1)))
        VStack(alignment: .leading, spacing: 3) {
          Text(suggestion.title).font(.system(size: 13, weight: .semibold))
          Text(suggestion.detail).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(2)
            .multilineTextAlignment(.leading)
        }
        Spacer(minLength: 0)
      }
      .padding(12)
      .frame(maxWidth: .infinity, minHeight: 72, maxHeight: 72, alignment: .topLeading)
      .background(RoundedRectangle(cornerRadius: 12).fill(hover && enabled ? Theme.raised : Theme.surface))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(suggestion.isGoal ? Theme.accent.opacity(0.4) : Theme.line.opacity(0.6)))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .opacity(enabled ? 1 : 0.5)
    .onHover { hover = $0 }
  }
}

/// Lays children out left to right and wraps them onto new lines.
struct FlowRow: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width { x = 0; y += line + 6; line = 0 }
      x += size.width + spacing
      line = max(line, size.height)
      widest = max(widest, x - spacing)
    }
    return CGSize(width: min(widest, width), height: y + line)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + 6; line = 0 }
      view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
      x += size.width + spacing
      line = max(line, size.height)
    }
  }
}
