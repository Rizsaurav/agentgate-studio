import AgentGateCore
import SwiftUI

/// The plan and its review, shown before the first byte downloads. Only the user starts the install.
struct PlanReviewSheet: View {
  @Environment(AppModel.self) private var app
  let review: AppModel.PendingReview

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Install \(review.model.name)?").font(.system(size: 17, weight: .semibold))
      Text("\(review.plan.quant.rawValue) · \(review.plan.context / 1024)K context · \(ModelPlanner.gb(review.plan.downloadBytes)) download · \(ModelPlanner.gb(review.plan.memoryBytes)) memory")
        .font(.system(size: 12)).foregroundStyle(Theme.muted)
      ForEach(Array(review.verdicts.enumerated()), id: \.offset) { _, verdict in
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: verdict.kind == .ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(verdict.kind == .ok ? Theme.accent : Theme.danger).accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 4) {
            Text(verdict.note).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            Text(verdict.source == .rules ? "Checked by fixed code" : "Supervising agent")
              .font(.system(size: 11)).foregroundStyle(Theme.muted)
            if let id = verdict.suggestedModelId, let other = app.catalogModel(id) {
              Button("Review \(other.name) instead") { app.reviewInstead(other) }.controlSize(.small)
            }
          }
        }
        .accessibilityElement(children: .combine)
      }
      if review.checking {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("The supervising agent is looking at the plan…").font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
      }
      HStack {
        Spacer()
        Button("Cancel") { app.cancelReview() }.keyboardShortcut(.cancelAction)
        Button("Install") { app.confirmReview() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
      }
    }
    .padding(22)
    .frame(width: 460)
  }
}
