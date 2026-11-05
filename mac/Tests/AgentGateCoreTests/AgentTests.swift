import Foundation
import Testing

@testable import AgentGateCore

private func decode(_ json: String) -> AgentEvent? { AgentEventDecoder.decode(Data(json.utf8)) }

@Suite struct AgentEventTests {
  @Test func decodesWhatTheHarnessSends() {
    #expect(decode(#"{"type":"message.part.delta","properties":{"sessionID":"s","messageID":"m","partID":"p1","field":"text","delta":"The"}}"#)
      == .textDelta(partID: "p1", messageID: "m", delta: "The"))
    #expect(decode(#"{"type":"message.part.updated","properties":{"sessionID":"s","part":{"id":"p2","type":"text","text":"Hello","messageID":"m","sessionID":"s"}}}"#)
      == .text(partID: "p2", messageID: "m", text: "Hello"))
    #expect(decode(#"{"type":"message.part.updated","properties":{"part":{"id":"p3","type":"tool","tool":"bash","state":{"status":"running","input":{"command":"ls -la"}}}}}"#)
      == .tool(.init(id: "p3", name: "bash", status: "running", detail: "ls -la", output: "")))
    #expect(decode(#"{"type":"message.part.updated","properties":{"part":{"id":"p4","type":"tool","tool":"edit","state":{"status":"completed","input":{"filePath":"a.txt"},"output":"ok"}}}}"#)
      == .tool(.init(id: "p4", name: "edit", status: "completed", detail: "a.txt", output: "ok")))
    #expect(decode(#"{"type":"permission.asked","properties":{"id":"per_1","sessionID":"s","permission":"bash","patterns":["cat notes.txt"],"metadata":{"command":"cat notes.txt"},"always":["cat *"]}}"#)
      == .permission(.init(id: "per_1", tool: "bash", detail: "cat notes.txt")))
    #expect(decode(#"{"type":"message.updated","properties":{"info":{"id":"msg_1","role":"assistant","sessionID":"s"}}}"#)
      == .message(id: "msg_1", role: "assistant"))
    #expect(decode(#"{"type":"session.status","properties":{"sessionID":"s","status":{"type":"busy"}}}"#) == .busy)
    #expect(decode(#"{"type":"server.connected","properties":{}}"#) == .connected)
    #expect(decode(#"{"type":"session.idle","properties":{"sessionID":"s"}}"#) == .idle)
    #expect(decode(#"{"type":"session.error","properties":{"error":{"name":"APIError","data":{"message":"model not found"}}}}"#)
      == .failed("model not found"))
  }

  @Test func ignoresEventsItDoesNotKnow() {
    #expect(decode(#"{"type":"server.heartbeat","properties":{}}"#) == nil)
    #expect(decode(#"{"type":"catalog.updated","properties":{}}"#) == nil)
    #expect(decode("not json") == nil)
  }

  @Test func configurationFailsClosed() throws {
    let text = try AgentServer.config(engineURL: URL(string: "http://127.0.0.1:1234")!, engineKey: "k", model: "qwen", context: 32768)
    let json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    let permission = try #require(json["permission"] as? [String: String])
    #expect(permission["bash"] == "ask" && permission["edit"] == "ask")
    #expect(permission["webfetch"] == "deny" && permission["external_directory"] == "deny")
    #expect(json["autoupdate"] as? Bool == false)
    let provider = try #require((json["provider"] as? [String: Any])?["local"] as? [String: Any])
    #expect((provider["options"] as? [String: String])?["baseURL"] == "http://127.0.0.1:1234/v1")
    let limit = ((provider["models"] as? [String: Any])?["qwen"] as? [String: Any])?["limit"] as? [String: Int]
    #expect(limit?["context"] == 32768)
  }
}
