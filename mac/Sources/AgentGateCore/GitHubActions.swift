import Foundation

/// A GitHub repository, from a project's git remote.
public struct GitHubRepo: Sendable, Equatable, Hashable, CustomStringConvertible {
  public var owner: String
  public var name: String
  public var description: String { "\(owner)/\(name)" }

  /// Accepts https://github.com/o/r(.git), git@github.com:o/r(.git) and ssh://git@github.com/o/r. Nothing else.
  public static func parse(_ remote: String) -> GitHubRepo? {
    let r = remote.trimmingCharacters(in: .whitespacesAndNewlines)
    let pattern = #"^(?:https://(?:www\.)?github\.com/|git@github\.com:|ssh://git@github\.com/)([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?$"#
    guard let match = r.range(of: pattern, options: .regularExpression) else { return nil }
    let parts = r[match].replacingOccurrences(of: #"^(?:https://(?:www\.)?github\.com/|git@github\.com:|ssh://git@github\.com/)"#, with: "", options: .regularExpression)
      .replacingOccurrences(of: #"(?:\.git)?/?$"#, with: "", options: .regularExpression).split(separator: "/")
    guard parts.count == 2 else { return nil }
    return GitHubRepo(owner: String(parts[0]), name: String(parts[1]))
  }

  public enum Detection: Sendable, Equatable {
    case found(GitHubRepo, branch: String?)
    case notGitHub
    /// git did not answer in time. On macOS this is usually the system asking for permission to read the folder
    /// (Desktop, Documents and Downloads are protected), so it is not reported as "not a repository".
    case timedOut
  }

  /// The repository and current branch of a project folder, read with git.
  public static func detect(folder: URL, timeout: TimeInterval = 10) -> Detection {
    let remote = run("/usr/bin/git", ["-C", folder.path, "remote", "get-url", "origin"], timeout: timeout)
    if remote.timedOut { return .timedOut }
    guard let text = remote.output, let repo = parse(text) else { return .notGitHub }
    let branch = run("/usr/bin/git", ["-C", folder.path, "rev-parse", "--abbrev-ref", "HEAD"], timeout: timeout).output?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return .found(repo, branch: branch == "HEAD" ? nil : branch)
  }

  public static func of(folder: URL) -> (repo: GitHubRepo, branch: String?)? {
    if case .found(let repo, let branch) = detect(folder: folder) { return (repo, branch) }
    return nil
  }

  static func run(_ exe: String, _ args: [String]) -> String? { run(exe, args, timeout: 10).output }

  static func run(_ exe: String, _ args: [String], timeout: TimeInterval) -> (output: String?, timedOut: Bool) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: exe)
    process.arguments = args
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return (nil, false) }
    let killed = Flag()
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
      if process.isRunning { killed.set(); process.terminate() }
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if killed.value { return (nil, true) }
    return (process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil, false)
  }
}

final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var raised = false
  func set() { lock.withLock { raised = true } }
  var value: Bool { lock.withLock { raised } }
}

public struct WorkflowRun: Decodable, Sendable, Identifiable, Equatable {
  public struct Actor: Decodable, Sendable, Equatable { public var login: String }
  public var id: Int
  public var name: String?
  public var display_title: String
  public var head_branch: String?
  public var head_sha: String
  public var event: String
  public var status: String
  public var conclusion: String?
  public var run_number: Int
  public var run_attempt: Int?
  public var created_at: Date
  public var run_started_at: Date?
  public var updated_at: Date
  public var html_url: String
  public var actor: Actor?

  public var workflow: String { name ?? "Workflow" }
  public var isActive: Bool { status != "completed" }
  /// Wall-clock time from start to the last update, or to now while it runs.
  public func duration(now: Date = Date()) -> TimeInterval {
    max(0, (isActive ? now : updated_at).timeIntervalSince(run_started_at ?? created_at))
  }
  public var outcome: Outcome { Outcome(status: status, conclusion: conclusion) }
}

public struct Job: Decodable, Sendable, Identifiable, Equatable {
  public struct Step: Decodable, Sendable, Equatable, Identifiable {
    public var id: Int { number }
    public var name: String
    public var status: String
    public var conclusion: String?
    public var number: Int
    public var started_at: Date?
    public var completed_at: Date?
    public var outcome: Outcome { Outcome(status: status, conclusion: conclusion) }
    public func duration(now: Date = Date()) -> TimeInterval? {
      guard let start = started_at else { return nil }
      return max(0, (completed_at ?? now).timeIntervalSince(start))
    }
  }
  public var id: Int
  public var name: String
  public var status: String
  public var conclusion: String?
  public var started_at: Date?
  public var completed_at: Date?
  public var html_url: String?
  public var steps: [Step]?
  public var outcome: Outcome { Outcome(status: status, conclusion: conclusion) }
}

/// One state for runs, jobs and steps, in plain words.
public enum Outcome: String, Sendable, Equatable {
  case passed, failed, cancelled, skipped, running, queued, other

  init(status: String, conclusion: String?) {
    switch (status, conclusion) {
    case ("completed", "success"?): self = .passed
    case ("completed", "failure"?), ("completed", "timed_out"?), ("completed", "startup_failure"?): self = .failed
    case ("completed", "cancelled"?): self = .cancelled
    case ("completed", "skipped"?), ("completed", "neutral"?): self = .skipped
    case ("in_progress", _): self = .running
    case ("queued", _), ("waiting", _), ("pending", _), ("requested", _): self = .queued
    default: self = .other
    }
  }
}

public enum CIError: Error, Equatable, CustomStringConvertible {
  case ghMissing, notSignedIn, notFound, rateLimited, failed(String)
  public var description: String {
    switch self {
    case .ghMissing: "The GitHub CLI (gh) is not installed. Install it with Homebrew: brew install gh."
    case .notSignedIn: "gh is not signed in. Run gh auth login in the terminal."
    case .notFound: "GitHub could not find this repository, or this account cannot see it."
    case .rateLimited: "GitHub's rate limit was reached. It resets within the hour."
    case .failed(let why): "GitHub request failed: \(why)"
    }
  }
}

/// Talks to the GitHub API. The app never sees a token: it asks `gh`, which holds the user's sign-in.
public protocol GitHubTransport: Sendable {
  func get(_ path: String) async throws -> Data
  func post(_ path: String) async throws
}

public struct GhCLI: GitHubTransport {
  public static let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
  public var executable: String?

  public init(executable: String? = GhCLI.candidates.first { FileManager.default.isExecutableFile(atPath: $0) }) {
    self.executable = executable
  }

  public func get(_ path: String) async throws -> Data { try await run(["api", path]) }
  public func post(_ path: String) async throws { _ = try await run(["api", "-X", "POST", path]) }

  func run(_ args: [String]) async throws -> Data {
    guard let executable else { throw CIError.ghMissing }
    return try await withCheckedThrowingContinuation { continuation in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = args
      var env = ProcessInfo.processInfo.environment.filter { ["HOME", "PATH", "TMPDIR", "LANG"].contains($0.key) }
      env["GH_PROMPT_DISABLED"] = "1"
      env["NO_COLOR"] = "1"
      process.environment = env
      let out = Pipe(), err = Pipe()
      process.standardOutput = out
      process.standardError = err
      let output = Collected(), errors = LogTail()
      out.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; if d.isEmpty { h.readabilityHandler = nil } else { output.append(d) } }
      err.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; if d.isEmpty { h.readabilityHandler = nil } else { errors.append(d) } }
      process.terminationHandler = { p in
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        if output.overflowed { continuation.resume(throwing: CIError.failed("the answer was larger than \(Collected.limit / 1_048_576) MB")); return }
        if p.terminationStatus == 0 { continuation.resume(returning: output.data); return }
        continuation.resume(throwing: Self.error(from: errors.text + String(decoding: output.data.prefix(4096), as: UTF8.self)))
      }
      do { try process.run() } catch { continuation.resume(throwing: CIError.ghMissing); return }
      DispatchQueue.global().asyncAfter(deadline: .now() + 30) { if process.isRunning { process.terminate() } }
    }
  }

  /// Turns gh's messages into a fixed sentence. Its own output is never shown, since it can contain URLs and names.
  static func error(from text: String) -> CIError {
    let t = text.lowercased()
    if t.contains("gh auth login") || t.contains("not logged") || t.contains("authentication") { return .notSignedIn }
    if t.contains("http 404") || t.contains("not found") { return .notFound }
    if t.contains("rate limit") { return .rateLimited }
    return .failed("gh exited with an error")
  }
}

/// Keeps all of a command's output, up to a hard limit. (LogTail keeps only the end, which cuts JSON in half.)
final class Collected: @unchecked Sendable {
  static let limit = 16 * 1_048_576
  private let lock = NSLock()
  private var buffer = Data()
  private(set) var overflowed = false

  func append(_ chunk: Data) {
    lock.withLock {
      if buffer.count + chunk.count > Self.limit { overflowed = true } else { buffer.append(chunk) }
    }
  }

  var data: Data { lock.withLock { buffer } }
}

/// Reads and acts on one repository's GitHub Actions.
public struct ActionsService: Sendable {
  public var repo: GitHubRepo
  public var transport: any GitHubTransport

  public init(repo: GitHubRepo, transport: any GitHubTransport = GhCLI()) {
    self.repo = repo
    self.transport = transport
  }

  static let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }()

  public func runs(branch: String? = nil, count: Int = 40) async throws -> [WorkflowRun] {
    struct Page: Decodable { var workflow_runs: [WorkflowRun] }
    var path = "repos/\(repo)/actions/runs?per_page=\(min(max(count, 1), 100))"
    if let branch, let escaped = branch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { path += "&branch=\(escaped)" }
    return try Self.decoder.decode(Page.self, from: try await transport.get(path)).workflow_runs
  }

  public func jobs(runID: Int) async throws -> [Job] {
    struct Page: Decodable { var jobs: [Job] }
    return try Self.decoder.decode(Page.self, from: try await transport.get("repos/\(repo)/actions/runs/\(runID)/jobs?per_page=100")).jobs
  }

  /// The end of a job's log, cleaned of timestamps and colour codes, with keys and private paths removed.
  public func logTail(jobID: Int, lines: Int = 120) async throws -> String {
    let raw = String(decoding: try await transport.get("repos/\(repo)/actions/jobs/\(jobID)/logs"), as: UTF8.self)
    return Self.clean(raw, lines: lines)
  }

  /// The part of the log that explains the failure: the lines up to the last `##[error]` GitHub wrote, or the end.
  static func clean(_ raw: String, lines: Int) -> String {
    let all = raw.split(separator: "\n", omittingEmptySubsequences: false)
    let end = (all.lastIndex { $0.contains("##[error]") }).map { min($0 + 2, all.count) } ?? all.count
    let body = all[max(0, end - lines)..<end].map { line -> String in
      var s = String(line)
      s = s.replacingOccurrences(of: #"^\d{4}-\d{2}-\d{2}T[0-9:.]+Z\s?"#, with: "", options: .regularExpression)
      s = s.replacingOccurrences(of: #"\x{1B}\[[0-9;]*m"#, with: "", options: .regularExpression)
      return s
    }.joined(separator: "\n")
    return Redaction.clean(body, root: FileManager.default.homeDirectoryForCurrentUser, label: "~")
  }

  public func rerunFailedJobs(runID: Int) async throws { try await transport.post("repos/\(repo)/actions/runs/\(runID)/rerun-failed-jobs") }
  public func cancel(runID: Int) async throws { try await transport.post("repos/\(repo)/actions/runs/\(runID)/cancel") }
}

/// What the history says about one workflow. Every figure comes from the runs given; nothing is estimated beyond them.
public struct WorkflowHistory: Sendable, Identifiable, Equatable {
  public var id: String { workflow }
  public var workflow: String
  /// Newest first.
  public var outcomes: [Outcome]
  public var completed: Int
  public var passed: Int
  public var medianSeconds: TimeInterval?
  /// Commits whose runs both failed and passed: flaky, not broken.
  public var flakyCommits: Int
  public var passRate: Double? { completed == 0 ? nil : Double(passed) / Double(completed) }

  public static func from(_ runs: [WorkflowRun]) -> [WorkflowHistory] {
    Dictionary(grouping: runs, by: \.workflow).map { name, items in
      let sorted = items.sorted { $0.created_at > $1.created_at }
      let done = sorted.filter { [.passed, .failed].contains($0.outcome) }
      let durations = sorted.filter { $0.outcome == .passed }.map { $0.duration() }.sorted()
      let median = durations.isEmpty ? nil : durations[durations.count / 2]
      let byCommit = Dictionary(grouping: done, by: \.head_sha)
      let flaky = byCommit.values.filter { runs in Set(runs.map(\.outcome)).isSuperset(of: [.passed, .failed]) }.count
      return WorkflowHistory(
        workflow: name, outcomes: sorted.map(\.outcome), completed: done.count,
        passed: done.filter { $0.outcome == .passed }.count, medianSeconds: median, flakyCommits: flaky)
    }
    .sorted { $0.workflow < $1.workflow }
  }
}

public enum RunProgress {
  /// Finished steps over all steps known so far, across jobs.
  public static func steps(_ jobs: [Job]) -> (done: Int, total: Int) {
    let steps = jobs.flatMap { $0.steps ?? [] }
    return (steps.filter { $0.status == "completed" }.count, steps.count)
  }

  /// Seconds left, from this workflow's median passing duration. Nil when there is no history to go on.
  public static func remaining(_ run: WorkflowRun, history: WorkflowHistory?, now: Date = Date()) -> TimeInterval? {
    guard run.isActive, let median = history?.medianSeconds else { return nil }
    return max(0, median - run.duration(now: now))
  }
}
