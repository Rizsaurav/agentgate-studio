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
        StepPill(step: current, state: failed ? .failed : current == .ready ? .done : .active)
        Text("Step \(current.rawValue + 1) of \(InstallStep.allCases.count)").font(.caption).foregroundStyle(.secondary)
      }
      .fixedSize()
    } else {
      HStack(spacing: 12) {
        ForEach(InstallStep.allCases, id: \.self) { step in
          StepPill(step: step, state: state(step, current: current, failed: failed))
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
