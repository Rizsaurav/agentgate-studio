import Foundation
import Testing

@testable import AgentGateCore

/// A clock the test moves by hand.
final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var time = Date(timeIntervalSince1970: 1_800_000_000)
  var now: Date { lock.withLock { time } }
  func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
}

// Assembled at runtime so the repository never contains a key-shaped string.
private let keys = [
  "sk-" + "or-v1-" + String(repeating: "Ab3x9Kq7", count: 6),
  "gh" + "p_" + String(repeating: "Ab3x9Kq7", count: 5),
  "github" + "_pat_" + String(repeating: "Ab3x9Kq7", count: 4),
  "AK" + "IA" + "ABCDEFGHIJ012345",
  "AI" + "za" + String(repeating: "Ab3x9Kq7", count: 4) + "Ab3",
  "xa" + "i-" + String(repeating: "Ab3x9Kq7", count: 4),
  "gs" + "k_" + String(repeating: "Ab3x9Kq7", count: 4),
  "ey" + "JhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJlc2lnbmF0dXJl",
]

@Suite struct TraceRecorderTests {
  let folder = URL(fileURLWithPath: "/Users/someone/Projects/app")

  func recorder(_ clock: TestClock) -> TraceRecorder {
    TraceRecorder(folder: folder, project: "app", now: { clock.now })
  }

  // Acceptance: every tool call in a turn appears in the trace in order, with its duration.
  @Test func everyToolCallAppearsInOrderWithItsDuration() throws {
    let clock = TestClock()
    let trace = recorder(clock)
    trace.beginTurn()
    trace.tool(id: "t1", name: "read", status: "pending", detail: "src/a.swift", output: "")
    clock.advance(0.25)
    trace.tool(id: "t1", name: "read", status: "running", detail: "src/a.swift", output: "")
    trace.tool(id: "t2", name: "bash", status: "running", detail: "npm test", output: "")
    clock.advance(1.5)
    trace.tool(id: "t1", name: "read", status: "completed", detail: "src/a.swift", output: "let a = 1")
    clock.advance(2)
    trace.tool(id: "t2", name: "bash", status: "error", detail: "npm test", output: "1 failing")
    trace.tool(id: "t2", name: "bash", status: "completed", detail: "npm test", output: "late duplicate")
    trace.refused(id: "t3", name: "read", detail: "../../etc/passwd", reason: "outside-project")
    let done = try #require(trace.finishTurn())
    #expect(done.spans.map(\.id) == ["t1", "t2", "t3"])
    #expect(done.spans.map(\.outcome) == [.completed, .failed, .refused])
    #expect(done.spans[0].duration == 1.75)
    #expect(done.spans[1].duration == 3.5)
    #expect(done.spans[1].output == "1 failing", "a late update cannot change a finished call")
    #expect(done.spans[2].duration == 0)
    #expect(trace.current == nil)
  }

  @Test func aCallStillRunningWhenTheTurnEndsIsMarkedStopped() throws {
    let clock = TestClock()
    let trace = recorder(clock)
    trace.beginTurn()
    trace.tool(id: "t1", name: "bash", status: "running", detail: "sleep 100", output: "")
    clock.advance(4)
    let done = try #require(trace.finishTurn())
    #expect(done.spans[0].outcome == .failed)
    #expect(done.spans[0].duration == 4)
    #expect(done.spans[0].output == "Stopped when the turn ended.")
    #expect(done.duration == 4)
  }

  @Test func modelCallsCarryTokensAndCostAndTheTurnAddsThemUp() throws {
    let clock = TestClock()
    let trace = recorder(clock)
    trace.beginTurn()
    let start = clock.now
    trace.model(id: "m1", name: "deepseek-v4.1-flash", start: start, end: start + 2, tokensIn: 1200, tokensOut: 300, cost: 0.0012)
    trace.tool(id: "t1", name: "read", status: "completed", detail: "a", output: "")
    trace.model(id: "m2", name: "deepseek-v4.1-flash", start: start + 3, end: start + 4, tokensIn: 1500, tokensOut: 80, cost: 0.0009)
    let done = try #require(trace.finishTurn())
    #expect(done.spans.map(\.kind) == [.model, .tool, .model])
    #expect(done.tokensIn == 2700)
    #expect(done.tokensOut == 380)
    #expect(abs(done.cost - 0.0021) < 1e-9)
  }

  @Test func updatesBeforeBeginTurnStartOne() {
    let trace = recorder(TestClock())
    trace.tool(id: "t1", name: "read", status: "running", detail: "a", output: "")
    #expect(trace.current?.spans.count == 1)
  }

  // Acceptance: redaction removes keys and private paths.
  @Test func keysAndPrivatePathsNeverReachTheTrace() throws {
    let trace = recorder(TestClock())
    trace.beginTurn()
    for (index, key) in keys.enumerated() {
      trace.tool(id: "k\(index)", name: "bash", status: "completed", detail: "echo \(key)", output: "got \(key) back")
    }
    trace.tool(
      id: "p", name: "read", status: "completed", detail: "/Users/someone/Projects/app/src/main.swift",
      output: "see /Users/someone/.ssh/config and /private/var/folders/xy/T/tmp1")
    trace.refused(id: "r", name: "bash", detail: "curl -H 'Authorization: Bearer abc.def.ghi' x", reason: "api_key=hunter2hunter2")
    let pem = "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC\n-----END PRIVATE KEY-----"
    trace.tool(id: "pem", name: "read", status: "completed", detail: "key.pem", output: pem)
    let done = try #require(trace.finishTurn())
    let text = String(decoding: try TraceStore.export(done, folder: folder), as: UTF8.self)
    for key in keys { #expect(!text.contains(key), "\(key.prefix(6))…") }
    #expect(!text.contains("/Users/someone"))
    #expect(!text.contains("/private/var/folders"))
    #expect(!text.contains("hunter2"))
    #expect(!text.contains("MIIEvQIBADAN"))
    #expect(done.spans.first(where: { $0.id == "p" })?.detail == "<project>/src/main.swift")
    #expect(text.contains("<secret>"))
  }

  @Test func longOutputIsCut() throws {
    let trace = recorder(TestClock())
    trace.tool(id: "t", name: "bash", status: "completed", detail: String(repeating: "d", count: 900), output: String(repeating: "o", count: 9000))
    let span = try #require(trace.finishTurn()?.spans.first)
    #expect(span.detail.count == TraceRecorder.detailLimit)
    #expect(span.output.count == TraceRecorder.outputLimit)
    #expect(span.output.hasSuffix("…"))
  }
}

@Suite struct TraceStoreTests {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traces-\(UUID().uuidString)")

  func finished(_ clock: TestClock, spans: Int = 1) -> Trace {
    let trace = TraceRecorder(folder: URL(fileURLWithPath: "/x"), project: "app", now: { clock.now })
    trace.beginTurn()
    for index in 0..<spans {
      trace.tool(id: "t\(index)", name: "read", status: "running", detail: "a", output: "")
      clock.advance(0.123)
      trace.tool(id: "t\(index)", name: "read", status: "completed", detail: "a", output: "ok")
    }
    return trace.finishTurn()!
  }

  @Test func savedTracesComeBackNewestFirstWithMillisecondDurations() throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TraceStore(directory: directory)
    let clock = TestClock()
    let first = finished(clock)
    clock.advance(60)
    let second = finished(clock, spans: 2)
    try store.save(first)
    try store.save(second)
    let listed = try store.list()
    #expect(listed.map(\.id) == [second.id, first.id])
    #expect(abs((listed[1].spans[0].duration ?? 0) - 0.123) < 0.0015)
    let file = try #require(try FileManager.default.contentsOfDirectory(atPath: directory.path).first)
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(file).path)
    #expect(attributes[.posixPermissions] as? Int == 0o600)
  }

  @Test func onlyTheNewestAreKeptAndBadFilesAreSkipped() throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TraceStore(directory: directory, keep: 3)
    let clock = TestClock()
    var ids: [UUID] = []
    for _ in 0..<5 {
      clock.advance(1)
      let trace = finished(clock)
      ids.append(trace.id)
      try store.save(trace)
    }
    try Data("{broken".utf8).write(to: directory.appendingPathComponent("9999999999999-bad.json"))
    #expect(try store.list().map(\.id) == Array(ids.suffix(3).reversed()))
  }

  // Acceptance: the trace can be exported for a bug report.
  @Test func theExportIsReadableJSONThatDecodesBack() throws {
    let trace = finished(TestClock(), spans: 2)
    let data = try TraceStore.export(trace, folder: URL(fileURLWithPath: "/x"))
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\n"), "pretty printed")
    #expect(text.contains("\"name\" : \"read\""))
    let back = try TraceStore.decoder.decode(Trace.self, from: data)
    #expect(back.spans.map(\.id) == ["t0", "t1"])
  }
}

@Suite struct RedactionTests {
  @Test func everyKnownKeyFormatIsRemoved() {
    for key in keys {
      let cleaned = Redaction.clean("before \(key) after", root: URL(fileURLWithPath: "/nowhere"), label: "<p>")
      #expect(!cleaned.contains(key), "\(key.prefix(6))…")
      #expect(cleaned.hasPrefix("before ") && cleaned.hasSuffix(" after"))
    }
  }

  @Test func ordinaryTextIsLeftAlone() {
    for text in ["npm test", "Model qwen3:8b on port 8080", "skip-this task", "git push origin main"] {
      #expect(Redaction.clean(text, root: URL(fileURLWithPath: "/nowhere"), label: "<p>") == text)
    }
  }
}
