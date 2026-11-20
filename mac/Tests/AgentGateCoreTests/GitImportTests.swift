import Foundation
import Testing

@testable import AgentGateCore

@Suite struct GitImportTests {
  // MARK: URLs

  @Test(arguments: [
    ("https://github.com/Rizsaurav/agentgate-studio", "agentgate-studio"),
    ("https://github.com/owner/repo.git", "repo"),
    ("  https://gitlab.com/group/sub/project  ", "project"),
    ("git@github.com:owner/repo.git", "repo"),
    ("ssh://git@github.com/owner/repo.git", "repo"),
  ])
  func acceptsHttpsAndSshRemotes(text: String, name: String) throws {
    #expect(try GitRemote.parse(text).name == name)
  }

  @Test(arguments: [
    "", "not a url", "-uhttps://github.com/a/b", "file:///etc/repo", "ext::sh -c touch% /tmp/x",
    "http://github.com/owner/repo", "https://github.com/owner", "https://github.com/owner/..",
    "https://-host/owner/repo", "https://github.com/owner/repo\nmore",
  ])
  func rejectsAnythingElseBeforeRunningGit(text: String) {
    #expect(throws: GitImportError.notAGitURL) { try GitRemote.parse(text) }
  }

  @Test func refusesCredentialsInTheURL() {
    #expect(throws: GitImportError.credentialInURL) { try GitRemote.parse("https://me:ghp_secret@github.com/owner/repo") }
    #expect(throws: GitImportError.credentialInURL) { try GitRemote.parse("https://ghp_secret@github.com/owner/repo") }
  }

  // MARK: Failures in plain words

  @Test func classifiesGitErrors() {
    #expect(GitImportError.classify("fatal: unable to access 'https://x/': Could not resolve host: x") == .noNetwork)
    #expect(GitImportError.classify("remote: Repository not found.\nfatal: repository 'https://github.com/a/b/' not found") == .noAccess)
    #expect(GitImportError.classify("fatal: could not read Username for 'https://github.com': terminal prompts disabled") == .noAccess)
    #expect(GitImportError.classify("git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.") == .noAccess)
    #expect(GitImportError.classify("fatal: repository 'https://example.com/a/b/' not found") == .notARepository)
    #expect(GitImportError.classify("fatal: '/tmp/x' does not appear to be a git repository") == .notARepository)
    #expect(GitImportError.classify("error: unable to write file x: No space left on device") == .diskFull)
    #expect(GitImportError.classify("fatal: something odd\nlast line") == .failed("last line"))
  }

  @Test func readsGitProgress() {
    #expect(GitCloner.progress("Receiving objects:  50% (5/10), 1.00 MiB") == 0.5)
    #expect(GitCloner.progress("Resolving deltas: 100% (3/3), done.") == 1.0)
    #expect(GitCloner.progress("Cloning into 'repo'...") == nil)
  }

  // MARK: Cloning a real repository

  @Test func clonesShallowThenFetchesFullHistory() async throws {
    let work = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: work) }
    let origin = try makeRepository(in: work, commits: 3)
    let cloner = local()
    let folder = try await cloner.clone(remote(origin), into: work.appendingPathComponent("projects"))
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Package.swift").path))
    #expect(GitCloner.isShallow(folder))
    #expect(try git(["rev-list", "--count", "HEAD"], in: folder) == "1")
    try await cloner.fetchFullHistory(folder)
    #expect(!GitCloner.isShallow(folder))
    #expect(try git(["rev-list", "--count", "HEAD"], in: folder) == "3")
    #expect(ProjectSummary.detect(folder).testCommand == "swift test")
  }

  @Test func somethingThatIsNotARepositoryIsRejectedBeforeAnyDownload() async throws {
    let work = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: work) }
    let plain = work.appendingPathComponent("plain/folder")
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
    let projects = work.appendingPathComponent("projects")
    await #expect(throws: GitImportError.notARepository) {
      _ = try await local().clone(GitRemote(url: plain.absoluteString, name: "folder"), into: projects)
    }
    #expect(!FileManager.default.fileExists(atPath: projects.appendingPathComponent("folder").path))
  }

  @Test func anExistingFolderIsNeverOverwritten() async throws {
    let work = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: work) }
    let origin = try makeRepository(in: work, commits: 1)
    let projects = work.appendingPathComponent("projects")
    try FileManager.default.createDirectory(at: projects.appendingPathComponent("origin"), withIntermediateDirectories: true)
    await #expect(throws: GitImportError.self) { _ = try await local().clone(remote(origin), into: projects) }
  }

  @Test func cancellingACloneRemovesThePartialFolder() async throws {
    let work = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: work) }
    // A stand-in git: the check passes, the clone writes part of the folder and then hangs.
    let fake = work.appendingPathComponent("git")
    try """
      #!/bin/sh
      if [ "$1" = "ls-remote" ]; then exit 0; fi
      for last; do :; done
      mkdir -p "$last/.git" && echo partial > "$last/half-written"
      exec sleep 30
      """.write(to: fake, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    let projects = work.appendingPathComponent("projects")
    let task = Task { try await GitCloner(git: fake).clone(try GitRemote.parse("https://example.com/owner/slow"), into: projects) }
    let partial = projects.appendingPathComponent("slow/half-written")
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: partial.path) { try await Task.sleep(for: .milliseconds(50)) }
    #expect(FileManager.default.fileExists(atPath: partial.path))
    task.cancel()
    await #expect(throws: GitImportError.cancelled) { _ = try await task.value }
    #expect(!FileManager.default.fileExists(atPath: projects.appendingPathComponent("slow").path))
  }

  // MARK: Detection

  @Test func detectsCommonProjects() throws {
    let work = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: work) }
    func project(_ files: [String: String]) throws -> ProjectSummary {
      let folder = work.appendingPathComponent(UUID().uuidString)
      for (path, text) in files {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
      }
      return ProjectSummary.detect(folder)
    }
    #expect(try project(["package.json": #"{"scripts":{"test":"vitest"}}"#, "pnpm-lock.yaml": "", "tsconfig.json": "{}",
                         ".github/workflows/ci.yml": ""])
            == ProjectSummary(language: "TypeScript", packageManager: "pnpm", testCommand: "pnpm test", ci: "GitHub Actions"))
    #expect(try project(["package.json": "{}"]).testCommand == "")
    #expect(try project(["pyproject.toml": "", "uv.lock": "", ".gitlab-ci.yml": ""])
            == ProjectSummary(language: "Python", packageManager: "uv", testCommand: "pytest", ci: "GitLab CI"))
    #expect(try project(["Cargo.toml": ""]).testCommand == "cargo test")
    #expect(try project(["go.mod": ""]).language == "Go")
    #expect(try project(["README.md": ""]) == ProjectSummary(language: "", packageManager: "", testCommand: "", ci: ""))
  }

  @Test func projectsSavedBeforeDetectionStillLoad() throws {
    let old = #"{"id":"5A0E3A6C-0000-4000-8000-000000000000","name":"Old","createdAt":0,"folder":"/tmp/old"}"#
    let project = try JSONDecoder().decode(Project.self, from: Data(old.utf8))
    #expect(project.summary == nil)
  }

  // MARK: Helpers

  private func local() -> GitCloner {
    var cloner = GitCloner()
    cloner.allowedProtocols = "file"
    return cloner
  }

  private func remote(_ origin: URL) -> GitRemote { GitRemote(url: origin.absoluteString, name: origin.lastPathComponent) }

  private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("gitimport-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
  }

  private func makeRepository(in work: URL, commits: Int) throws -> URL {
    let origin = work.appendingPathComponent("origin", isDirectory: true)
    try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
    _ = try git(["init", "-q", "-b", "main"], in: origin)
    for n in 1...commits {
      try "// \(n)\n".write(to: origin.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
      _ = try git(["add", "."], in: origin)
      _ = try git(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "c\(n)"], in: origin)
    }
    return origin
  }

  @discardableResult
  private func git(_ args: [String], in folder: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", folder.path] + args
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// Against real servers. Run with AGENTGATE_LIVE_GIT=1; skipped otherwise, so CI needs no network.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AGENTGATE_LIVE_GIT"] == "1"))
struct GitImportLiveTests {
  @Test func clonesAPublicRepositoryFromItsURL() async throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent("gitlive-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: parent) }
    let folder = try await GitCloner().clone(try GitRemote.parse("https://github.com/octocat/Hello-World"), into: parent)
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("README").path))
    #expect(GitCloner.isShallow(folder))
    // Nothing about credentials is written into the clone's config.
    let config = try String(contentsOf: folder.appendingPathComponent(".git/config"), encoding: .utf8)
    #expect(config.contains("url = https://github.com/octocat/Hello-World\n"))
  }

  @Test func explainsAMissingRepositoryAndANonGitAddress() async throws {
    let cloner = GitCloner()
    await #expect(throws: GitImportError.noAccess) {
      try await cloner.check(try GitRemote.parse("https://github.com/octocat/this-repository-does-not-exist-\(UUID().uuidString.prefix(8))"))
    }
    await #expect(throws: GitImportError.self) {
      try await cloner.check(try GitRemote.parse("https://example.com/owner/project"))
    }
  }
}
