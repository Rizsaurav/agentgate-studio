import AgentGateCore
import SwiftUI

/// The live strip along the bottom: every install step, what is happening now, and why.
struct InstallStrip: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    if let repair = app.pendingRepair {
      bar(step: app.update?.step ?? .download, failed: true, message: "\(repair.report.message) Proposed repair: \(repair.operation.summary)",
          progress: nil, trailing: AnyView(HStack {
            Button("Decline") { app.answerRepair(false) }.controlSize(.small)
            Button("Approve") { app.answerRepair(true) }.controlSize(.small).buttonStyle(.borderedProminent)
          }))
    } else if let failure = app.failure {
      bar(step: failure.step, failed: true, message: failure.message, progress: nil, trailing: AnyView(
        Button("Dismiss") { app.dismissFailure() }.controlSize(.small)))
    } else if let update = app.update {
      let progress = update.totalBytes > 0 ? Double(update.completedBytes) / Double(update.totalBytes) : nil
      bar(step: update.step, failed: false, message: update.message, progress: update.step == .download ? progress : nil,
          trailing: AnyView(Group {
            if app.installing != nil { Button("Cancel") { app.cancelInstall() }.controlSize(.small) }
            else { Button { app.dismissUpdate() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless) }
          }))
    }
  }

  private func bar(step current: InstallStep, failed: Bool, message: String, progress: Double?, trailing: AnyView) -> some View {
    VStack(spacing: 0) {
      if let progress { ProgressView(value: progress).progressViewStyle(.linear).tint(.accentColor) }
      else { Divider() }
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 14) {
          if let name = app.installing?.name ?? app.active?.name {
            Text(name).font(.callout.weight(.semibold)).lineLimit(1).fixedSize()
          }
          ViewThatFits(in: .horizontal) {
            steps(current, failed: failed, compact: false)
            steps(current, failed: failed, compact: true)
          }
          Spacer(minLength: 8)
          Text(app.agentOn ? "Agent watching" : "Agent off")
            .font(.caption).foregroundStyle(app.agentOn ? Theme.accent : .secondary).fixedSize()
            .help("Every step runs as fixed code. The agent only acts when a step fails, and you approve anything that deletes or changes the model.")
          trailing
        }
        Text(message).font(.callout).foregroundStyle(failed ? .red : .secondary).lineLimit(2)
          .textSelection(.enabled)
      }
      .padding(.horizontal, 14).padding(.vertical, 9)
    }
    .background(.bar)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Model install")
  }

  /// All eight steps when they fit; otherwise only the finished count and the current step.
  @ViewBuilder private func steps(_ current: InstallStep, failed: Bool, compact: Bool) -> some View {
    if compact {
      HStack(spacing: 6) {
        Button { app.stepDetail = current } label: {
          StepPill(step: current, state: failed ? .failed : current == .ready ? .done : .active)
        }
        .buttonStyle(.plain)
        Text("Step \(current.rawValue + 1) of \(InstallStep.allCases.count)").font(.caption).foregroundStyle(.secondary)
      }
      .fixedSize()
    } else {
      HStack(spacing: 12) {
        ForEach(InstallStep.allCases, id: \.self) { step in
          Button { app.stepDetail = step } label: {
            StepPill(step: step, state: state(step, current: current, failed: failed))
          }
          .buttonStyle(.plain).help("What happened at \(step.title)")
        }
      }
      .fixedSize()
    }
  }

  private func state(_ step: InstallStep, current: InstallStep, failed: Bool) -> StepPill.State {
    if step < current || (step == .ready && current == .ready) { return .done }
    if step == current { return failed ? .failed : .active }
    return .pending
  }
}

private struct StepPill: View {
  enum State { case pending, active, done, failed }
  let step: InstallStep
  let state: State
  @SwiftUI.State private var pulse = false

  var body: some View {
    HStack(spacing: 4) {
      ZStack {
        switch state {
        case .pending: Circle().strokeBorder(.secondary.opacity(0.6), lineWidth: 1)
        case .done: Circle().fill(Color.accentColor)
        case .failed: Image(systemName: "xmark.circle.fill").resizable().foregroundStyle(.red)
        case .active:
          Circle().fill(Color.accentColor).opacity(pulse ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(), value: pulse)
            .onAppear { pulse = true }
        }
      }
      .frame(width: 8, height: 8)
      Text(step.title).font(.caption.weight(state == .active ? .semibold : .regular))
        .foregroundStyle(state == .pending ? .secondary : .primary)
        .lineLimit(1).fixedSize()
    }
    .accessibilityLabel("\(step.title): \(label)")
  }

  private var label: String {
    switch state {
    case .pending: "waiting"
    case .active: "in progress"
    case .done: "done"
    case .failed: "failed"
    }
  }
}

/// What one install step did, in the words the installer used while it ran.
struct StepSheet: View {
  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss
  let step: InstallStep

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text(step.title).font(.system(size: 17, weight: .semibold))
        Spacer()
        Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      Text(blurb).font(.system(size: 12)).foregroundStyle(Theme.muted)
      let lines = app.stepLog[step] ?? []
      if lines.isEmpty {
        Text("Nothing ran for this step in this session.").foregroundStyle(Theme.muted)
      }
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        Text(line).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
      }
      if let failure = app.failure, failure.step == step {
        Divider().overlay(Theme.line)
        Text(failure.message).foregroundStyle(Theme.danger).textSelection(.enabled)
        if let tail = failure.logTail, !tail.isEmpty {
          Text(String(tail.suffix(1500))).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
            .textSelection(.enabled)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(22)
    .frame(minWidth: 480, idealWidth: 560, minHeight: 240, idealHeight: 320)
    .background(Theme.bg)
    .preferredColorScheme(.dark)
  }

  /// Who does the step: all are fixed code, and the agent only steps in after a failure.
  private var blurb: String {
    switch step {
    case .hardware: "Fixed code reads this Mac's chip, memory and disk."
    case .compatibility: "Fixed code checks the model fits in memory and on disk."
    case .quantization: "Fixed code picks the best quality that fits. No model is involved."
    case .download: "Fixed code downloads, resumes and checks the file's checksum."
    case .configure: "Fixed code sets context size and GPU use for this Mac."
    case .load: "The bundled engine loads the model into memory."
    case .test: "A short reply, then a tool call, prove the model works."
    case .ready: "Installed and checked."
    }
  }
}
