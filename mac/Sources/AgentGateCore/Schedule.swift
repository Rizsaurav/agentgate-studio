import Foundation

/// A task the agent runs on a schedule in a project, such as "run the tests and fix what fails" every weekday at
/// 9:00. It runs while the app is open; a time missed while the Mac slept or the app was closed runs once at the
/// next check, never several times in a row.
public struct ScheduledTask: Codable, Sendable, Equatable, Identifiable {
  public var id = UUID()
  public var projectId: UUID
  public var text: String
  /// Run as a goal in rounds instead of a single turn.
  public var asGoal: Bool
  public var hour: Int
  public var minute: Int
  /// Calendar weekdays, 1 = Sunday … 7 = Saturday. Empty means every day.
  public var weekdays: Set<Int>
  public var enabled = true
  public var createdAt: Date
  public var lastRun: Date?

  public init(
    projectId: UUID, text: String, asGoal: Bool = false, hour: Int, minute: Int, weekdays: Set<Int> = [],
    createdAt: Date = Date()
  ) {
    self.projectId = projectId
    self.text = text
    self.asGoal = asGoal
    self.hour = min(max(hour, 0), 23)
    self.minute = min(max(minute, 0), 59)
    self.weekdays = weekdays.filter { (1...7).contains($0) }
    self.createdAt = createdAt
  }

  /// The most recent time this task should have run at or before `now`, or nil if none since it was created.
  public func lastSlot(before now: Date, calendar: Calendar = .current) -> Date? {
    for daysBack in 0...7 {
      guard let day = calendar.date(byAdding: .day, value: -daysBack, to: now),
            let slot = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { continue }
      guard slot <= now else { continue }
      if !weekdays.isEmpty, !weekdays.contains(calendar.component(.weekday, from: slot)) { continue }
      return slot >= createdAt ? slot : nil
    }
    return nil
  }

  /// Due when a slot has passed since the last run (or since it was created).
  public func isDue(at now: Date, calendar: Calendar = .current) -> Bool {
    guard enabled, let slot = lastSlot(before: now, calendar: calendar) else { return false }
    return lastRun.map { $0 < slot } ?? true
  }

  /// "Every day at 09:00", "Mon, Wed, Fri at 18:30".
  public func summary(calendar: Calendar = .current) -> String {
    let time = String(format: "%02d:%02d", hour, minute)
    if weekdays.isEmpty || weekdays.count == 7 { return "Every day at \(time)" }
    if weekdays == [2, 3, 4, 5, 6] { return "Weekdays at \(time)" }
    let names = calendar.shortWeekdaySymbols
    return weekdays.sorted().map { names[$0 - 1] }.joined(separator: ", ") + " at \(time)"
  }
}

/// Scheduled tasks on disk (0600), one small file for all projects.
public struct ScheduleStore: Sendable {
  public let file: URL

  public init(file: URL = AppPaths.support.appendingPathComponent("schedules.json")) {
    self.file = file
  }

  public func load() -> [ScheduledTask] {
    guard let data = try? Data(contentsOf: file) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode([ScheduledTask].self, from: data)) ?? []
  }

  public func save(_ tasks: [ScheduledTask]) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(tasks).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
}
