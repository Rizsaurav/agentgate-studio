import Foundation
import Testing

@testable import AgentGateCore

/// Every test here works in a throwaway temporary folder. Nothing outside it is written or deleted.
@Suite(.serialized) struct AgentSandboxTests {
  struct Box {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sandbox-\(UUID().uuidString)")
    var project: URL { root.appendingPathComponent("project") }
    var outside: URL { root.appendingPathComponent("outside") }
    var fakeHome: URL { root.appendingPathComponent("home") }

    init() throws {
      for dir in [project, outside, fakeHome.appendingPathComponent(".ssh")] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      }
      try Data("keep me".utf8).write(to: outside.appendingPathComponent("precious.txt"))
      try Data("secret".utf8).write(to: fakeHome.appendingPathComponent(".ssh/id_ed25519"))
    }

    /// Runs a shell command inside a sandbox that may write only the project (no temp folders, to keep this strict).
    func run(_ command: String) throws -> Int32 {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: AgentSandbox.executable)
      process.arguments = ["-p", AgentSandbox.profile(writable: [project], home: fakeHome), "/bin/sh", "-c", command]
      process.currentDirectoryURL = project
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus
    }
  }

  @Test func insideTheProjectWorks() throws {
    let box = try Box()
    defer { try? FileManager.default.removeItem(at: box.root) }
    #expect(try box.run("echo hi > made.txt && mkdir sub && rm made.txt") == 0)
    #expect(FileManager.default.fileExists(atPath: box.project.appendingPathComponent("sub").path))
  }

  @Test func deletingOutsideTheProjectIsRefusedByTheSystem() throws {
    let box = try Box()
    defer { try? FileManager.default.removeItem(at: box.root) }
    #expect(try box.run("rm -rf '\(box.outside.path)'") != 0)
    #expect(try box.run("echo x > '\(box.outside.path)/new.txt'") != 0)
    #expect(try box.run("mv '\(box.outside.path)/precious.txt' .") != 0)
    #expect(FileManager.default.fileExists(atPath: box.outside.appendingPathComponent("precious.txt").path))
    #expect(!FileManager.default.fileExists(atPath: box.outside.appendingPathComponent("new.txt").path))
  }

  @Test func keysCannotBeReadEvenFromInside() throws {
    let box = try Box()
    defer { try? FileManager.default.removeItem(at: box.root) }
    #expect(try box.run("cat '\(box.fakeHome.path)/.ssh/id_ed25519'") != 0)
    #expect(try box.run("cp '\(box.fakeHome.path)/.ssh/id_ed25519' stolen") != 0)
    #expect(!FileManager.default.fileExists(atPath: box.project.appendingPathComponent("stolen").path))
  }

  @Test func childProcessesInheritTheSandbox() throws {
    let box = try Box()
    defer { try? FileManager.default.removeItem(at: box.root) }
    // A script that starts another shell is held to the same limits.
    #expect(try box.run("/bin/bash -c \"/bin/zsh -c 'touch \(box.outside.path)/deep.txt'\"") != 0)
    #expect(!FileManager.default.fileExists(atPath: box.outside.appendingPathComponent("deep.txt").path))
  }

  @Test func pathsWithQuotesCannotBreakTheProfile() {
    let tricky = URL(fileURLWithPath: "/tmp/a\") (allow file-write* (subpath \"/")
    let text = AgentSandbox.profile(writable: [tricky], home: URL(fileURLWithPath: "/tmp/h"))
    #expect(!text.contains("(allow file-write* (subpath \"/\")"))
  }
}
