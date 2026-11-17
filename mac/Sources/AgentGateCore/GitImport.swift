import Foundation

/// A Git remote the user typed, checked before anything runs.
///
/// Only https and ssh remotes are accepted. Credentials in the URL are refused: the app never takes or
/// stores a token. Private repositories use the user's own Git setup (credential helper or SSH key).
public struct GitRemote: Sendable, Equatable {
  /// The URL exactly as passed to git.
  public let url: String
  /// A folder and project name derived from the repository name, e.g. "agentgate-studio".
  public let name: String

  public static func parse(_ text: String) throws -> GitRemote {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // A leading dash would be read by git as an option.
    guard !trimmed.isEmpty, !trimmed.hasPrefix("-"), trimmed.count <= 2048,
          !trimmed.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\0" }) else {
      throw GitImportError.notAGitURL
    }
    let path: String
    if let scp = trimmed.wholeMatch(of: /git@([A-Za-z0-9.\-]+):([A-Za-z0-9._\-\/]+)/) {
      // scp-like syntax: git@github.com:owner/repo.git
      _ = scp.1
      path = String(scp.2)
    } else {
      guard let url = URLComponents(string: trimmed), let scheme = url.scheme?.lowercased(),
            ["https", "ssh"].contains(scheme), let host = url.host, !host.isEmpty, !host.hasPrefix("-") else {
        throw GitImportError.notAGitURL
      }
      // https://user:token@host/... would put a credential in the project's .git/config.
      if url.password != nil || (scheme == "https" && url.user != nil) { throw GitImportError.credentialInURL }
      path = url.path
    }
    let parts = path.split(separator: "/").map(String.init)
    guard parts.count >= 2, !parts.contains(".."), var repo = parts.last else { throw GitImportError.notAGitURL }
    if repo.hasSuffix(".git") { repo.removeLast(4) }
    guard repo.wholeMatch(of: /[A-Za-z0-9._\-]{1,80}/) != nil, repo != ".", !repo.hasPrefix(".") else {
      throw GitImportError.notAGitURL
    }
    return GitRemote(url: trimmed, name: repo)
  }
}

public enum GitImportError: Error, Equatable, CustomStringConvertible {
  case notAGitURL
  case credentialInURL
  case notARepository
  case noAccess
  case noNetwork
  case diskFull
  case folderExists(String)
  case cancelled
  case gitMissing
  case failed(String)

  public var description: String {
    switch self {
    case .notAGitURL:
      "That is not a Git URL. Paste an https:// or git@ address, such as https://github.com/owner/repo."
    case .credentialInURL:
      "Remove the user name or token from the URL. Private repositories use your Git sign-in or SSH key; the app never stores a token."
    case .notARepository:
      "Nothing was downloaded: that address is not a Git repository. Check the URL on the repository's page."
    case .noAccess:
      "The repository was not found or you have no access. For a private repository, sign in with git (for example `gh auth login`) or add your SSH key, then try again."
    case .noNetwork:
      "Could not reach the server. Check your internet connection and try again."
    case .diskFull:
      "The disk is full. Free some space and try again; the partial download was removed."
    case .folderExists(let path):
      "A folder named \(URL(fileURLWithPath: path).lastPathComponent) already exists in your projects folder. Open it as a folder instead, or rename it."
    case .cancelled:
      "The download was cancelled and the partial folder removed."
    case .gitMissing:
      "Git is not installed. Install the Xcode Command Line Tools (xcode-select --install) and try again."
    case .failed(let detail):
      "Git could not download the repository: \(detail)"
    }
  }

  /// Reads git's error output. Order matters: git prints several lines and the first match wins.
  static func classify(_ stderr: String) -> GitImportError {
    let text = stderr.lowercased()
    if text.contains("no space left on device") || text.contains("disk quota exceeded") { return .diskFull }
    if ["could not resolve host", "could not resolve hostname", "failed to connect", "connection timed out",
        "network is unreachable", "connection refused", "operation timed out"].contains(where: text.contains) {
      return .noNetwork
    }
    if ["repository not found", "authentication failed", "permission denied", "could not read username",
        "terminal prompts disabled", "access denied", "403"].contains(where: text.contains) { return .noAccess }
    if text.contains("not a git repository") || text.contains("does not appear to be a git repository") || text.contains("not found") || text.contains("invalid") { return .notARepository }
    // The last line is usually the reason; credentials never reach here (URLs with them are refused).
    let last = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "unknown error"
    return .failed(String(last.prefix(200)))
  }
}

/// Clones a remote with the system git. Shallow by default; nothing prompts in a terminal.
public struct GitCloner: Sendable {
  public var git: URL
  /// Transports git may use. Tests add `file` to clone a local repository.
  var allowedProtocols = "https:ssh"
  public var checkTimeout: TimeInterval = 30

  public init(git: URL = URL(fileURLWithPath: "/usr/bin/git")) { self.git = git }

  /// Fails before any download when the address is not a reachable Git repository.
  public func check(_ remote: GitRemote) async throws {
    _ = try await run(["ls-remote", "--heads", "--", remote.url], timeout: checkTimeout)
  }

  /// Clones `remote` into `parent/<name>`, reporting progress in 0...1. The folder is removed if the
  /// clone fails or is cancelled. Returns the new folder.
  public func clone(
    _ remote: GitRemote, into parent: URL, shallow: Bool = true, progress: @escaping @Sendable (Double) -> Void = { _ in }
  ) async throws -> URL {
    let destination = parent.appendingPathComponent(remote.name, isDirectory: true)
    guard !FileManager.default.fileExists(atPath: destination.path) else { throw GitImportError.folderExists(destination.path) }
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try await check(remote)
    var args = ["clone", "--progress"]
    if shallow { args += ["--depth", "1"] }
    args += ["--", remote.url, destination.path]
    do {
      _ = try await run(args, timeout: nil) { line in
        if let fraction = Self.progress(line) { progress(fraction) }
      }
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
    progress(1)
    return destination
  }

  /// Downloads the rest of the history of a shallow clone.
  public func fetchFullHistory(_ folder: URL) async throws {
    guard Self.isShallow(folder) else { return }
    _ = try await run(["-C", folder.path, "fetch", "--unshallow"], timeout: nil)
  }

  public static func isShallow(_ folder: URL) -> Bool {
    FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git/shallow").path)
  }

  /// Overall progress from a git progress line: receiving objects counts for most of it.
  static func progress(_ line: String) -> Double? {
    guard let match = line.firstMatch(of: /(Counting|Compressing|Receiving|Resolving) (objects|deltas):\s+(\d+)%/),
          let percent = Double(match.3) else { return nil }
    let share = percent / 100
    switch match.1 {
    case "Receiving": return 0.1 + share * 0.8
    case "Resolving": return 0.9 + share * 0.1
    default: return share * 0.1
    }
  }

  /// Runs git and returns its output. A non-zero exit is classified from stderr; cancellation stops git.
  func run(_ args: [String], timeout: TimeInterval?, onProgress: (@Sendable (String) -> Void)? = nil) async throws -> String {
    guard FileManager.default.isExecutableFile(atPath: git.path) else { throw GitImportError.gitMissing }
    let process = Process()
    process.executableURL = git
    process.arguments = args
    var env = ProcessInfo.processInfo.environment
    // Never wait on a password prompt the user cannot see; use existing helpers and keys only.
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["GIT_ASKPASS"] = "/usr/bin/false"
    env["SSH_ASKPASS"] = "/usr/bin/false"
    env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=15"
    env["GIT_ALLOW_PROTOCOL"] = allowedProtocols
    process.environment = env
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    let collected = LockedText()
    let output = LockedText()
    // Both pipes are drained while git runs: a full pipe would stop git before it exits.
    out.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty { handle.readabilityHandler = nil } else { output.append(String(decoding: data, as: UTF8.self)) }
    }
    err.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty { handle.readabilityHandler = nil; return }
      let text = String(decoding: data, as: UTF8.self)
      collected.append(text)
      // git redraws progress with carriage returns.
      for line in text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) { onProgress?(String(line)) }
    }
    let exit = ExitWait()
    process.terminationHandler = { exit.finish($0.terminationStatus) }
    try process.run()
    // Cancelling or timing out stops git; either way the wait below lasts until git has really exited,
    // so the folder is never removed while git is still writing to it.
    let timedOut = LockedText()
    let timer = timeout.map { seconds in
      Task {
        try await Task.sleep(for: .seconds(seconds))
        timedOut.append("yes")
        process.terminate()
      }
    }
    let status = await withTaskCancellationHandler {
      await exit.wait()
    } onCancel: {
      process.terminate()
    }
    timer?.cancel()
    out.fileHandleForReading.readabilityHandler = nil
    err.fileHandleForReading.readabilityHandler = nil
    output.append(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    collected.append(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    if Task.isCancelled { throw GitImportError.cancelled }
    if !timedOut.text.isEmpty { throw GitImportError.noNetwork }
    guard status == 0 else { throw GitImportError.classify(collected.text) }
    return output.text
  }
}

/// The exit status of a process, awaited once. Not cancellable on purpose: see `GitCloner.run`.
private final class ExitWait: @unchecked Sendable {
  private let lock = NSLock()
  private var status: Int32?
  private var waiter: CheckedContinuation<Int32, Never>?

  func finish(_ code: Int32) {
    let resume: CheckedContinuation<Int32, Never>? = lock.withLock {
      status = code
      defer { waiter = nil }
      return waiter
    }
    resume?.resume(returning: code)
  }

  func wait() async -> Int32 {
    await withCheckedContinuation { continuation in
      let done: Int32? = lock.withLock {
        if status == nil { waiter = continuation }
        return status
      }
      if let done { continuation.resume(returning: done) }
    }
  }
}

private final class LockedText: @unchecked Sendable {
  private let lock = NSLock()
  private var value = ""
  func append(_ text: String) { lock.withLock { value += text } }
  var text: String { lock.withLock { value } }
}

/// What the app could tell about a project from its files. Shown to the user, who can correct it.
public struct ProjectSummary: Codable, Sendable, Hashable {
  public var language: String
  public var packageManager: String
  public var testCommand: String
  public var ci: String

  public init(language: String, packageManager: String, testCommand: String, ci: String) {
    self.language = language
    self.packageManager = packageManager
    self.testCommand = testCommand
    self.ci = ci
  }

  /// Reads marker files at the top of `folder`. Nothing is run. Unknown fields are empty.
  public static func detect(_ folder: URL) -> ProjectSummary {
    let fm = FileManager.default
    func has(_ name: String) -> Bool { fm.fileExists(atPath: folder.appendingPathComponent(name).path) }
    var summary = ProjectSummary(language: "", packageManager: "", testCommand: "", ci: "")

    if has("Package.swift") {
      summary = .init(language: "Swift", packageManager: "Swift Package Manager", testCommand: "swift test", ci: "")
    } else if has("package.json") {
      let typescript = has("tsconfig.json")
      let manager = has("pnpm-lock.yaml") ? "pnpm" : has("yarn.lock") ? "yarn" : has("bun.lockb") || has("bun.lock") ? "bun" : "npm"
      let scripts = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("package.json"))) as? [String: Any])?["scripts"] as? [String: Any]
      let test = scripts?["test"] != nil ? (manager == "npm" ? "npm test" : "\(manager) test") : ""
      summary = .init(language: typescript ? "TypeScript" : "JavaScript", packageManager: manager, testCommand: test, ci: "")
    } else if has("Cargo.toml") {
      summary = .init(language: "Rust", packageManager: "Cargo", testCommand: "cargo test", ci: "")
    } else if has("go.mod") {
      summary = .init(language: "Go", packageManager: "Go modules", testCommand: "go test ./...", ci: "")
    } else if has("pyproject.toml") || has("requirements.txt") || has("setup.py") {
      let manager = has("uv.lock") ? "uv" : has("poetry.lock") ? "Poetry" : has("Pipfile") ? "Pipenv" : "pip"
      summary = .init(language: "Python", packageManager: manager, testCommand: "pytest", ci: "")
    } else if has("pom.xml") {
      summary = .init(language: "Java", packageManager: "Maven", testCommand: "mvn test", ci: "")
    } else if has("build.gradle") || has("build.gradle.kts") {
      summary = .init(language: has("build.gradle.kts") ? "Kotlin" : "Java", packageManager: "Gradle",
                      testCommand: has("gradlew") ? "./gradlew test" : "gradle test", ci: "")
    } else if has("Gemfile") {
      summary = .init(language: "Ruby", packageManager: "Bundler", testCommand: "bundle exec rake test", ci: "")
    }

    if has(".github/workflows") { summary.ci = "GitHub Actions" }
    else if has(".gitlab-ci.yml") { summary.ci = "GitLab CI" }
    else if has(".circleci") { summary.ci = "CircleCI" }
    else if has("Jenkinsfile") { summary.ci = "Jenkins" }
    return summary
  }
}
