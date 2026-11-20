import Foundation
import Testing

@testable import AgentGateCore

@Suite struct ComparisonTests {
  private func project() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("compare-\(UUID().uuidString)/app", isDirectory: true)
    for (path, text) in ["README.md": "hello", "Sources/main.swift": "print(1)", "old.txt": "x", ".git/HEAD": "ref"] {
      let url = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try text.write(to: url, atomically: true, encoding: .utf8)
    }
    return root
  }

  @Test func eachSideGetsItsOwnCopyAndTheProjectIsNeverChanged() throws {
    let original = try project()
    defer { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
    let scratch = original.deletingLastPathComponent().appendingPathComponent("scratch")
    let a = try ProjectCopy.make(of: original, in: scratch)
    let b = try ProjectCopy.make(of: original, in: scratch)
    #expect(a.folder != b.folder && a.folder.lastPathComponent == "app")
    #expect(try a.changes().isEmpty)

    try "print(2)".write(to: a.folder.appendingPathComponent("Sources/main.swift"), atomically: true, encoding: .utf8)
    try "new".write(to: a.folder.appendingPathComponent("NEW.md"), atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: a.folder.appendingPathComponent("old.txt"))
    try "ref2".write(to: a.folder.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)

    #expect(try a.changes() == ["+ NEW.md", "~ Sources/main.swift", "- old.txt"])
    // The other side and the project still see the original state.
    #expect(try b.changes().isEmpty)
    #expect(try String(contentsOf: original.appendingPathComponent("Sources/main.swift"), encoding: .utf8) == "print(1)")
    #expect(FileManager.default.fileExists(atPath: original.appendingPathComponent("old.txt").path))
    a.discard()
    #expect(!FileManager.default.fileExists(atPath: a.folder.path))
    #expect(FileManager.default.fileExists(atPath: original.path))
  }

  @Test func aHugeProjectIsRefusedRatherThanCopied() throws {
    let original = try project()
    defer { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
    #expect(throws: ComparisonError.tooManyFiles(2)) { _ = try ProjectCopy.stamps(original, limit: 2) }
  }

  @Test func comparisonsAreSavedWithTheSessionAndOldSessionsStillLoad() throws {
    let old = #"{"id":"5A0E3A6C-0000-4000-8000-000000000000","projectId":"5A0E3A6C-0000-4000-8000-000000000001","modelId":"m","modelName":"M","createdAt":0,"messages":[]}"#
    var session = try JSONDecoder().decode(Session.self, from: Data(old.utf8))
    #expect(session.comparisons == nil)
    session.comparisons = [Comparison(task: "t", sides: [
      ComparisonSide(modelId: "a", modelName: "A", answer: "x", tools: [.init(name: "read", detail: "README.md", status: "completed")],
                     seconds: 1.5, inputTokens: 10, outputTokens: 2, filesChanged: ["~ a.swift"]),
      ComparisonSide(modelId: "b", modelName: "B", error: "Stopped after 30 minutes."),
    ])]
    let again = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
    #expect(again == session)
  }

  @Test func tokensAreSummedFromTheHarnessMessages() async throws {
    let body = #"""
      [{"info":{"role":"user"}},
       {"info":{"role":"assistant","tokens":{"input":1200,"output":40,"reasoning":0}}},
       {"info":{"role":"assistant","tokens":{"input":1300,"output":60}}}]
      """#
    let server = try TestHTTPServer(body: Data(body.utf8), servedPath: "/session/s1/message")
    defer { server.stop() }
    let client = AgentClient(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, password: "p")
    let tokens = try await client.tokens(session: "s1")
    #expect(tokens?.input == 2500 && tokens?.output == 100)

    let none = try TestHTTPServer(body: Data(#"[{"info":{"role":"assistant"}}]"#.utf8), servedPath: "/session/s1/message")
    defer { none.stop() }
    #expect(try await AgentClient(baseURL: URL(string: "http://127.0.0.1:\(none.port)")!, password: "p").tokens(session: "s1") == nil)
  }
}

/// A real comparison through the bundled harness: two local models, each in its own copy of a project.
/// Needs AGENTGATE_LLAMA_DIR, AGENTGATE_OPENCODE_DIR, and AGENTGATE_COMPARE_GGUFS="<a.gguf>:<b.gguf>"; skipped otherwise.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AGENTGATE_COMPARE_GGUFS"] != nil))
struct ComparisonLiveTests {
  @Test func twoLocalModelsAnswerTheSameTaskInTheirOwnCopies() async throws {
    let files = ProcessInfo.processInfo.environment["AGENTGATE_COMPARE_GGUFS"]!.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("compare-live-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("demo", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try "The launch code word is PELICAN.\n".write(to: project.appendingPathComponent("NOTES.md"), atomically: true, encoding: .utf8)
    let task = "Read NOTES.md and tell me the launch code word. Then create a file ANSWER.txt containing only that word."

    for file in files {
      let copy = try ProjectCopy.make(of: project, in: root.appendingPathComponent("scratch"))
      defer { copy.discard() }
      let config = RuntimeConfig(context: 16384, gpuLayers: 999, kvCacheType: "q8_0", flashAttention: true, threads: 4)
      let runtime = try await LlamaRuntime.start(model: file, alias: "m", config: config)
      defer { runtime.stop() }
      let server = try await AgentServer.start(
        folder: copy.folder, engineURL: runtime.baseURL, engineKey: runtime.apiKey, model: "m", context: 16384)
      defer { server.stop() }
      let session = try await server.client.createSession(title: "compare")
      let start = Date()
      let folder = copy.folder
      let client = server.client
      let events = Task { () throws -> (tools: [String], answered: Bool) in
        var tools: [String] = []
        var answered = false
        for try await event in client.events() {
          switch event {
          // Like the app: calls inside the project are allowed (here without asking a person).
          case .permission(let p): try await client.reply(permission: p.id, allow: ToolCallCheck.check(p, folder: folder) == nil)
          case .tool(let t) where t.status == "completed": tools.append(t.name)
          case .text: answered = true
          case .idle: return (tools, answered)
          default: break
          }
        }
        return (tools, answered)
      }
      let timer = Task { try await Task.sleep(for: .seconds(600)); events.cancel() }
      try await Task.sleep(nanoseconds: 500_000_000)
      try await client.prompt(session: session, text: task, model: "m")
      let (tools, answered) = try await events.value
      timer.cancel()
      let tokens = try await server.client.tokens(session: session)
      let changed = try copy.changes()
      print("\(file.lastPathComponent): \(String(format: "%.1f", Date().timeIntervalSince(start))) s, tools \(tools), tokens \(String(describing: tokens)), changed \(changed)")
      #expect(answered || !tools.isEmpty)
      #expect(tokens != nil, "the harness reported no token counts")
      // The project itself never changes.
      #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("ANSWER.txt").path))
    }
  }
}
