import Foundation
import Testing

@testable import AgentGateCore

@Suite(.serialized) struct TokenCounterTests {
  func counter() -> (TokenCounter, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tokens-\(UUID().uuidString)")
    return (TokenCounter(file: dir.appendingPathComponent("tokens.json")), dir)
  }

  @Test func aChatGrowsTheModelsRowByTheReportedCounts() throws {
    let (c, dir) = counter()
    defer { try? FileManager.default.removeItem(at: dir) }
    try c.record(TokenUsage(prompt: 120, generated: 30), model: "qwen3-4b", name: "Qwen3 4B", location: .local)
    try c.record(TokenUsage(prompt: 200, generated: 50), model: "qwen3-4b", name: "Qwen3 4B", location: .local)
    let row = try #require(c.count(model: "qwen3-4b", location: .local))
    #expect(row.prompt == 320 && row.generated == 80 && row.total == 400 && row.unreported == 0)
  }

  @Test func countersSurviveARestartAndResetClearsOneModelOnly() throws {
    let (c, dir) = counter()
    defer { try? FileManager.default.removeItem(at: dir) }
    try c.record(TokenUsage(prompt: 10, generated: 5), model: "a", name: "A", location: .local)
    try c.record(TokenUsage(prompt: 7, generated: 3), model: "b", name: "B", location: .local)
    let reopened = TokenCounter(file: c.file)
    #expect(reopened.all().count == 2)
    try reopened.reset(model: "a", location: .local)
    #expect(reopened.count(model: "a", location: .local) == nil)
    #expect(reopened.count(model: "b", location: .local)?.total == 10)
  }

  @Test func localAndCloudAreSeparateRows() throws {
    let (c, dir) = counter()
    defer { try? FileManager.default.removeItem(at: dir) }
    try c.record(TokenUsage(prompt: 1, generated: 1), model: "m", name: "M", location: .local)
    try c.record(TokenUsage(prompt: 100, generated: 50), model: "m", name: "M", location: .cloud)
    #expect(c.all().map(\.location) == [.local, .cloud])
    #expect(c.total(.local) == 2 && c.total(.cloud) == 150)
  }

  @Test func aReplyWithoutUsageAddsNoTokens() throws {
    let (c, dir) = counter()
    defer { try? FileManager.default.removeItem(at: dir) }
    try c.record(nil, model: "m", name: "M", location: .local)
    let row = try #require(c.count(model: "m", location: .local))
    #expect(row.total == 0 && row.unreported == 1)
    #expect(TokenUsage.reported(prompt: -1, generated: 3) == nil)
    #expect(TokenUsage.reported(prompt: 1_000_000_000, generated: 3) == nil)
  }

  @Test func theFileHoldsCountsOnlyAndIsPrivate() throws {
    let (c, dir) = counter()
    defer { try? FileManager.default.removeItem(at: dir) }
    try c.record(TokenUsage(prompt: 3, generated: 4), model: "m", name: "M", location: .local)
    let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: c.file)) as? [[String: Any]])
    #expect(Set(json[0].keys) == ["model", "name", "location", "prompt", "generated", "unreported", "lastUsed"])
    let mode = try FileManager.default.attributesOfItem(atPath: c.file.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
  }

  @Test func theEnginesStepCountsAreRead() {
    let finish = #"{"type":"message.part.updated","properties":{"part":{"id":"prt_1","messageID":"msg_1","sessionID":"s","type":"step-finish","reason":"stop","cost":0,"tokens":{"input":900,"output":40,"reasoning":10,"cache":{"read":100,"write":0}}}}}"#
    #expect(AgentEventDecoder.decode(Data(finish.utf8)) == .usage(partID: "prt_1", TokenUsage(prompt: 1000, generated: 50)))
    let empty = #"{"type":"message.part.updated","properties":{"part":{"id":"prt_2","messageID":"msg_1","type":"step-finish","tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}}}}}"#
    #expect(AgentEventDecoder.decode(Data(empty.utf8)) == .usage(partID: "prt_2", nil))
  }

  @Test func cloudRepliesReportTheirUsage() async throws {
    let session = StubReplies.session(#"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":3}}"#)
    let seen = UsageBox()
    var assistant = AgentAssistant(apiKey: { "k" }, session: session)
    assistant.onUsage = { seen.set($0) }
    _ = try await assistant.complete(["model": "m"])
    #expect(seen.value == TokenUsage(prompt: 12, generated: 3))

    let bare = StubReplies.session(#"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#)
    var noUsage = AgentAssistant(apiKey: { "k" }, session: bare)
    let none = UsageBox()
    none.set(TokenUsage(prompt: 1, generated: 1))
    noUsage.onUsage = { none.set($0) }
    _ = try await noUsage.complete(["model": "m"])
    #expect(none.value == nil)
  }
}

final class UsageBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: TokenUsage?
  func set(_ value: TokenUsage?) { lock.lock(); stored = value; lock.unlock() }
  var value: TokenUsage? { lock.lock(); defer { lock.unlock() }; return stored }
}

/// Answers every request with one fixed JSON body.
final class StubReplies: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var body = Data()

  static func session(_ json: String) -> URLSession {
    body = Data(json.utf8)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubReplies.self]
    return URLSession(configuration: config)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Self.body)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
