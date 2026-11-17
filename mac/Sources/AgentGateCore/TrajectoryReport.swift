import Foundation

/// One model's results on the trajectory suite, in `evals/trajectory/results/<model>-<quant>.json`.
/// Pass/fail, repeats and flake history reuse the tool suite's report; the trajectories are added.
public struct TrajectoryReport: Codable, Sendable, Equatable {
  /// Per task: runs, passes, flaky. A task's category is its kind.
  public var score: ToolScoreReport
  /// The last run's trajectory of every task.
  public var records: [TrajectoryRecord]

  public init(score: ToolScoreReport, records: [TrajectoryRecord]) {
    self.score = score
    self.records = records
  }

  public func write(to folder: URL) throws -> URL {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("\(score.key).json")
    try (encoder.encode(self) + Data("\n".utf8)).write(to: url, options: .atomic)
    return url
  }

  public static func loadAll(from folder: URL) throws -> [TrajectoryReport] {
    guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .map { url in
        do { return try JSONDecoder().decode(TrajectoryReport.self, from: Data(contentsOf: url)) }
        catch { throw TrajectoryError.invalid("\(url.lastPathComponent) is not a results file (\(error))") }
      }
      .sorted { $0.score.key < $1.score.key }
  }

  /// A task that passed in `base` and fails in `head` is a regression, unless either side lists it as flaky.
  /// With a handful of tasks a percentage margin would hide a lost task, so each task counts.
  public static func regressions(base: [TrajectoryReport], head: [TrajectoryReport]) -> [String] {
    let now = Dictionary(head.map { ($0.score.key, $0) }, uniquingKeysWith: { a, _ in a })
    var lines: [String] = []
    for old in base {
      guard let new = now[old.score.key] else { lines.append("\(old.score.key): results were removed"); continue }
      let flaky = Set(old.score.flaky + new.score.flaky)
      let after = Dictionary(new.score.cases.map { ($0.id, $0.passed) }, uniquingKeysWith: { a, _ in a })
      for task in old.score.cases where task.passed && !flaky.contains(task.id) && after[task.id] != true {
        lines.append("\(old.score.key): \(task.id) passed before and fails now")
      }
    }
    return lines
  }

  public static func markdown(_ reports: [TrajectoryReport]) -> String {
    var lines = [
      "# Harness trajectory scores",
      "",
      "Generated from `evals/trajectory/results/` by `swift run --package-path mac agentgate-tooleval trajectory-report`. Do not edit by hand.",
      "",
      "Each task in `evals/trajectory/tasks/` is a small project. The bundled harness runs it through the app's model endpoint in a temporary copy, with calls answered by the app's own rules. A task passes when its outcome is right: the named test or build command succeeds, the right files contain the right text, nothing is written outside the project. Each model runs the suite on separate fresh engine loads; a task passes on a majority, and one whose runs disagree, or whose result changed since the previous committed run, is listed as flaky.",
      "",
    ]
    if reports.isEmpty { return (lines + ["No results yet.", ""]).joined(separator: "\n") }
    lines += ["| Model | Quant | Tasks passed | Engine | Mac | Date | Commit |", "| --- | --- | --- | --- | --- | --- | --- |"]
    for r in reports {
      let s = r.score
      lines.append("| \(s.model) | \(s.quant) | \(s.passed)/\(s.total) | \(s.engine) | \(s.hardware) | \(s.date) | `\(s.commit)` |")
    }
    for r in reports {
      lines += ["", "## \(r.score.model) \(r.score.quant)", "",
                "| Task | Kind | Passed | Steps | Approvals | Refused | Time | Tokens in/out | Reason (last run) |",
                "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
      for c in r.score.cases {
        let rec = r.records.first { $0.task == c.id }
        let tokens = rec.flatMap { r in r.inputTokens.map { "\($0)/\(r.outputTokens ?? 0)" } } ?? "–"
        let mark = r.score.flaky.contains(c.id) ? " (flaky)" : ""
        let reason = (rec?.reason ?? "").replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ")
        lines.append("| \(c.id) | \(c.category) | \(c.passes)/\(c.runs)\(mark) | \(rec?.steps.count ?? 0) | \(rec?.approvalsAsked ?? 0) | \(rec?.refused ?? 0) | \(Int(c.seconds.rounded())) s | \(tokens) | \(reason.prefix(120)) |")
      }
    }
    return (lines + [""]).joined(separator: "\n")
  }
}
