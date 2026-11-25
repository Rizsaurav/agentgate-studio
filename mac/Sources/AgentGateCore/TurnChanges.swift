import Foundation

/// One file a turn changed, with the lines it added and removed.
public struct FileChange: Codable, Sendable, Equatable, Identifiable {
  public enum Kind: String, Codable, Sendable { case added, modified, deleted }
  public var id: String { path }
  public var path: String
  public var added: Int
  public var removed: Int
  public var kind: Kind

  public init(path: String, added: Int, removed: Int, kind: Kind) {
    self.path = path
    self.added = added
    self.removed = removed
    self.kind = kind
  }
}

/// What a turn changed in a git project, measured against the state just before the turn, not against the last
/// commit: earlier uncommitted work is not counted again. Read-only for the user's files: the "before" state is
/// kept as an unreferenced git object (`git stash create`), which changes neither the working tree nor the stash list.
public struct TurnBaseline: Sendable, Equatable {
  /// The commit the turn is compared against: a snapshot of uncommitted work, or HEAD when there was none.
  public var commit: String
  /// Untracked files before the turn, with their content hashes, so new and changed ones can be told apart.
  public var untracked: [String: String]

  /// Records the state before a turn. Nil when the folder is not a git repository with at least one commit.
  public static func capture(_ folder: URL, timeout: TimeInterval = 10) -> TurnBaseline? {
    let git = { (args: [String]) in Git.run(["-C", folder.path] + args, timeout: timeout).output }
    guard let head = git(["rev-parse", "--verify", "-q", "HEAD"])?.trimmingCharacters(in: .whitespacesAndNewlines),
          !head.isEmpty else { return nil }
    let stash = git(["stash", "create"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return TurnBaseline(commit: stash.isEmpty ? head : stash, untracked: untrackedHashes(folder, timeout: timeout))
  }

  /// What changed since the baseline, largest change first.
  public func changes(in folder: URL, timeout: TimeInterval = 10) -> [FileChange] {
    let numstat = Git.run(["-C", folder.path, "diff", "--numstat", "-z", "--no-renames", commit], timeout: timeout).output ?? ""
    let status = Git.run(["-C", folder.path, "diff", "--name-status", "-z", "--no-renames", commit], timeout: timeout).output ?? ""
    var changes = Self.parse(numstat: numstat, status: status)
    let now = Self.untrackedHashes(folder, timeout: timeout)
    for (path, hash) in now where untracked[path] != hash {
      let lines = RepoScan.lineCount(folder.appendingPathComponent(path))
      changes.append(FileChange(path: path, added: lines, removed: 0, kind: untracked[path] == nil ? .added : .modified))
    }
    for path in untracked.keys where now[path] == nil && !FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path) {
      changes.append(FileChange(path: path, added: 0, removed: 0, kind: .deleted))
    }
    return changes.sorted { ($0.added + $0.removed, $1.path) > ($1.added + $1.removed, $0.path) }
  }

  /// `git diff --numstat -z` and `--name-status -z` output to changes. Binary files count as zero lines.
  static func parse(numstat: String, status: String) -> [FileChange] {
    var kinds: [String: FileChange.Kind] = [:]
    let fields = status.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    var index = 0
    while index + 1 < fields.count {
      let kind: FileChange.Kind = switch fields[index].first {
      case "A": .added
      case "D": .deleted
      default: .modified
      }
      kinds[fields[index + 1]] = kind
      index += 2
    }
    return numstat.split(separator: "\0", omittingEmptySubsequences: true).compactMap { record in
      let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
      guard parts.count == 3 else { return nil }
      let path = String(parts[2])
      return FileChange(path: path, added: Int(parts[0]) ?? 0, removed: Int(parts[1]) ?? 0, kind: kinds[path] ?? .modified)
    }
  }

  static func untrackedHashes(_ folder: URL, timeout: TimeInterval) -> [String: String] {
    let list = Git.run(["-C", folder.path, "ls-files", "-z", "--others", "--exclude-standard"], timeout: timeout).output ?? ""
    let paths = list.split(separator: "\0").map(String.init).prefix(2_000)
    guard !paths.isEmpty,
          let hashes = Git.run(["-C", folder.path, "hash-object", "--"] + paths, timeout: timeout).output?
            .split(whereSeparator: \.isNewline).map(String.init), hashes.count == paths.count
    else { return [:] }
    return Dictionary(zip(paths, hashes), uniquingKeysWith: { first, _ in first })
  }
}
