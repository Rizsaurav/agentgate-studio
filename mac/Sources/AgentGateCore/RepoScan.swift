import Foundation

/// What a project folder holds, for the overview on its page and for the goal's objective: languages, size,
/// git state and the command that checks it. Read-only: the scan never writes to the folder.
public struct RepoSummary: Sendable, Equatable {
  public struct Language: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var files: Int
    public var lines: Int
    /// Share of all counted lines, 0...1.
    public var share: Double
  }

  public var files: Int
  public var lines: Int
  /// Largest first. Languages under 1% of the lines are folded into "Other".
  public var languages: [Language]
  public var testCommand: String?
  public var branch: String?
  public var lastCommit: String?
  public var lastCommitDate: Date?
  /// Files with uncommitted changes.
  public var changed: Int
  public var isGit: Bool
  /// More files than the scan reads: counts are for the first `RepoScan.fileLimit`.
  public var truncated: Bool
  /// The project's files, relative to its folder, for @ mentions in the composer.
  public var paths: [String] = []
  /// The instructions file the agent reads at the start of every session, when the project has one.
  public var instructions: String?

  public var primaryLanguage: String? { languages.first { $0.name != "Other" }?.name }
}

public enum RepoScan {
  public static let fileLimit = 20_000
  /// Files larger than this are not counted for lines (generated code, data, minified bundles).
  static let lineCountLimit = 1_000_000
  static let skippedFolders: Set<String> = [
    ".git", "node_modules", ".build", "build", "dist", "DerivedData", ".venv", "venv", "__pycache__", "target",
    ".next", "Pods", ".gradle", "vendor",
  ]

  /// Extension → language. Only source languages; configuration and data files are not counted.
  static let languages: [String: String] = [
    "swift": "Swift", "py": "Python", "ts": "TypeScript", "tsx": "TypeScript", "js": "JavaScript",
    "jsx": "JavaScript", "mjs": "JavaScript", "cjs": "JavaScript", "go": "Go", "rs": "Rust", "java": "Java",
    "kt": "Kotlin", "kts": "Kotlin", "c": "C", "h": "C", "cc": "C++", "cpp": "C++", "hpp": "C++", "m": "Objective-C",
    "mm": "Objective-C", "cs": "C#", "rb": "Ruby", "php": "PHP", "scala": "Scala", "dart": "Dart", "lua": "Lua",
    "sh": "Shell", "zsh": "Shell", "bash": "Shell", "sql": "SQL", "html": "HTML", "css": "CSS", "scss": "CSS",
    "vue": "Vue", "svelte": "Svelte", "ex": "Elixir", "exs": "Elixir", "hs": "Haskell", "zig": "Zig", "r": "R",
  ]

  /// Scans a folder. Takes a second or two on a large repository, so call it off the main thread. Nil when git
  /// did not answer in time: on macOS that is usually the system asking for permission to read the folder
  /// (Desktop, Documents and Downloads are protected), and walking the folder would wait on the same prompt.
  public static func scan(_ folder: URL, timeout: TimeInterval = 10) -> RepoSummary? {
    let git = Git.run(["-C", folder.path, "ls-files", "-z", "--cached", "--others", "--exclude-standard"], timeout: timeout)
    if git.timedOut { return nil }
    let isGit = git.output != nil
    var paths = git.output.map { $0.split(separator: "\0").map(String.init) } ?? walk(folder)
    let truncated = paths.count > fileLimit
    paths = Array(paths.prefix(fileLimit))

    var counts: [String: (files: Int, lines: Int)] = [:]
    for path in paths {
      guard let language = language(of: path) else { continue }
      let lines = lineCount(folder.appendingPathComponent(path))
      counts[language, default: (0, 0)].files += 1
      counts[language, default: (0, 0)].lines += lines
    }

    var summary = RepoSummary(
      files: paths.count, lines: counts.values.reduce(0) { $0 + $1.lines }, languages: rank(counts),
      testCommand: testCommand(files: Set(paths), read: { try? String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) }),
      branch: nil, lastCommit: nil, lastCommitDate: nil, changed: 0, isGit: isGit, truncated: truncated)
    summary.paths = paths
    summary.instructions = FileManager.default.fileExists(atPath: folder.appendingPathComponent("AGENTS.md").path)
      ? "AGENTS.md" : nil
    if isGit {
      let branch = Git.run(["-C", folder.path, "rev-parse", "--abbrev-ref", "HEAD"], timeout: timeout).output?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      summary.branch = branch == "HEAD" ? nil : branch
      if let log = Git.run(["-C", folder.path, "log", "-1", "--format=%ct%x00%s"], timeout: timeout).output {
        let parts = log.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\0", maxSplits: 1)
        if parts.count == 2 {
          summary.lastCommitDate = TimeInterval(parts[0]).map(Date.init(timeIntervalSince1970:))
          summary.lastCommit = String(parts[1])
        }
      }
      summary.changed = Git.run(["-C", folder.path, "status", "--porcelain"], timeout: timeout).output?
        .split(whereSeparator: \.isNewline).count ?? 0
    }
    return summary
  }

  static func language(of path: String) -> String? {
    let ext = (path as NSString).pathExtension.lowercased()
    return ext.isEmpty ? nil : languages[ext]
  }

  /// Largest first, with the long tail under 1% folded into "Other" so the bar stays readable.
  static func rank(_ counts: [String: (files: Int, lines: Int)]) -> [RepoSummary.Language] {
    let total = max(counts.values.reduce(0) { $0 + $1.lines }, 1)
    let sorted = counts.sorted { $0.value.lines != $1.value.lines ? $0.value.lines > $1.value.lines : $0.key < $1.key }
    var result: [RepoSummary.Language] = []
    var other = (files: 0, lines: 0)
    for (name, count) in sorted {
      let share = Double(count.lines) / Double(total)
      if share < 0.01 || result.count >= 6 {
        other.files += count.files
        other.lines += count.lines
      } else {
        result.append(.init(name: name, files: count.files, lines: count.lines, share: share))
      }
    }
    if other.lines > 0 {
      result.append(.init(name: "Other", files: other.files, lines: other.lines, share: Double(other.lines) / Double(total)))
    }
    return result
  }

  /// The command that checks the project, from the files at its root. `read` returns a root file's text.
  static func testCommand(files: Set<String>, read: (String) -> String?) -> String? {
    if files.contains("Package.swift") { return "swift test" }
    if files.contains("package.json"), let text = read("package.json"),
       let data = text.data(using: .utf8),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let scripts = json["scripts"] as? [String: Any], let test = scripts["test"] as? String,
       !test.contains("no test specified") {
      if files.contains("pnpm-lock.yaml") { return "pnpm test" }
      if files.contains("yarn.lock") { return "yarn test" }
      return "npm test"
    }
    if files.contains("Cargo.toml") { return "cargo test" }
    if files.contains("go.mod") { return "go test ./..." }
    if files.contains("Makefile"), let text = read("Makefile"),
       text.split(whereSeparator: \.isNewline).contains(where: { $0.hasPrefix("test:") }) {
      return "make test"
    }
    let python = files.contains { path in
      let name = (path as NSString).lastPathComponent
      return name.hasSuffix(".py") && (name.hasPrefix("test_") || name.hasSuffix("_test.py"))
    }
    let pytest = files.contains("pytest.ini") || files.contains("conftest.py")
      || (read("pyproject.toml")?.contains("[tool.pytest") ?? false)
    if pytest { return "python3 -m pytest" }
    if python { return "python3 -m unittest" }
    return nil
  }

  /// Files under a folder that is not a git repository, skipping build and dependency folders.
  static func walk(_ folder: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(
      at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [.skipsHiddenFiles])
    else { return [] }
    let base = folder.standardizedFileURL.path + "/"
    var paths: [String] = []
    for case let url as URL in enumerator {
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
      if values?.isDirectory == true {
        if skippedFolders.contains(url.lastPathComponent) { enumerator.skipDescendants() }
        continue
      }
      guard values?.isRegularFile == true else { continue }
      paths.append(String(url.standardizedFileURL.path.dropFirst(base.count)))
      if paths.count > fileLimit { break }
    }
    return paths
  }

  static func lineCount(_ url: URL) -> Int {
    guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0, size <= lineCountLimit,
          let data = try? Data(contentsOf: url) else { return 0 }
    var lines = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
    if data.last != 0x0A { lines += 1 }
    return lines
  }
}
