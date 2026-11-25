import AgentGateCore
import SwiftUI

/// Tasks the agent runs in this project on a schedule, and a form to add one.
struct SchedulesCard: View {
  @Environment(AppModel.self) private var app
  let projectId: UUID
  @State private var text = ""
  @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
  @State private var weekdaysOnly = false
  @State private var asGoal = false

  private var tasks: [ScheduledTask] { app.schedules.filter { $0.projectId == projectId } }

  var body: some View {
    Card(padding: 18) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
          Image(systemName: "calendar.badge.clock").foregroundStyle(Theme.accent)
          Text("Scheduled tasks").font(.system(size: 14, weight: .semibold))
          Spacer()
          Text("Runs while the app is open").font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        ForEach(tasks) { task in
          HStack(spacing: 10) {
            Image(systemName: task.asGoal ? "scope" : "bubble.left").font(.system(size: 11)).foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 2) {
              Text(task.text).font(.system(size: 12.5)).lineLimit(1)
              Text(task.summary() + (task.lastRun.map { "  ·  last ran " + $0.formatted(.relative(presentation: .named)) } ?? ""))
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { task.enabled }, set: { app.setSchedule(task.id, enabled: $0) }))
              .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            Button { app.removeSchedule(task.id) } label: { Image(systemName: "trash") }
              .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Remove this schedule")
          }
        }
        TextField("Task, e.g. run the tests and fix what fails", text: $text).field()
          .accessibilityLabel("Scheduled task")
        HStack(spacing: 10) {
          DatePicker("At", selection: $time, displayedComponents: .hourAndMinute).labelsHidden().frame(width: 90)
          Picker("Days", selection: $weekdaysOnly) {
            Text("Every day").tag(false)
            Text("Weekdays").tag(true)
          }
          .labelsHidden().frame(width: 120)
          Toggle("As a goal", isOn: $asGoal).toggleStyle(.checkbox).font(.system(size: 12))
          Spacer()
          Button("Add") { add() }.buttonStyle(SubtleButtonStyle())
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
  }

  private func add() {
    let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
    app.addSchedule(ScheduledTask(
      projectId: projectId, text: text.trimmingCharacters(in: .whitespacesAndNewlines), asGoal: asGoal,
      hour: parts.hour ?? 9, minute: parts.minute ?? 0, weekdays: weekdaysOnly ? [2, 3, 4, 5, 6] : []))
    text = ""
  }
}
