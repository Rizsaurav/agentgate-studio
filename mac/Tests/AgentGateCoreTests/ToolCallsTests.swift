import Foundation
import Testing

@testable import AgentGateCore

/// J3: our check of every tool call before it runs.
@Suite struct ToolCallCheckTests {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("calls-\(UUID().uuidString)")
  var folder: URL { root.appendingPathComponent("project") }

  func check(_ tool: String, _ detail: String, path: String? = nil) -> ToolCallCheck.Rejection? {
    ToolCallCheck.check(AgentEvent.Permission(id: "per_1", tool: tool, detail: detail, path: path), folder: folder)
  }

  @Test func callsInsideTheProjectPass() {
    #expect(check("read", "src/app.swift") == nil)
    #expect(check("list", "") == nil)
    #expect(check("glob", "**/*.swift") == nil)
    #expect(check("glob", "*.md", path: "docs") == nil)
    #expect(check("grep", "TODO", path: "src") == nil)
    #expect(check("grep", "func [a-z]+\\(") == nil)
    #expect(check("bash", "npm test") == nil)
    #expect(check("edit", "a.swift, b/c.swift") == nil)
  }

  // Acceptance: read, glob and grep with paths outside the project are refused by us as well as by the sandbox.
  @Test(arguments: [
    ("read", "../../etc/passwd", nil as String?),
    ("read", "/etc/hosts", nil),
    ("list", "/Users", nil),
    ("glob", "../**/*", nil),
    ("glob", "/etc/*.conf", nil),
    ("glob", "~/Documents/*", nil),
    ("glob", "*.txt", "/etc"),
    ("grep", "password", "/etc"),
    ("grep", "password", "../.."),
    ("edit", "/etc/hosts", nil),
    ("write", "src/ok.swift, ../outside.swift", nil),
  ])
  func pathsOutsideTheProjectAreRefused(tool: String, detail: String, path: String?) throws {
    let rejection = try #require(check(tool, detail, path: path), "\(tool) \(detail) \(path ?? "")")
    #expect(rejection.rule == "outside-project")
    #expect(rejection.message.hasPrefix("\(tool):"))
    #expect(rejection.message.contains("inside the project") || rejection.message.contains("relative to the project root"))
  }

  @Test func aSymlinkOutOfTheProjectIsRefused() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: folder.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/etc"))
    #expect(check("read", "escape/hosts")?.rule == "outside-project")
    #expect(check("grep", "root", path: "escape")?.rule == "outside-project")
  }

  @Test func keyFilesAreRefusedWithTheirOwnReason() throws {
    let rejection = try #require(check("read", ".env"))
    #expect(rejection.rule == "credential-access")
    #expect(rejection.message == "read: \".env\" holds keys or credentials, which the agent may not open. Work without it.")
  }

  // Acceptance: malformed calls get a usable error, not a crash.
  @Test(arguments: [
    ("", "x", "malformed-call"),
    ("re ad", "a.txt", "malformed-call"),
    ("../../bin/sh", "x", "malformed-call"),
    (String(repeating: "t", count: 200), "x", "malformed-call"),
    ("delete_everything", "x", "unknown-tool"),
    ("read", "", "malformed-call"),
    ("read", "   ", "malformed-call"),
    ("read", "a\u{0}b", "malformed-call"),
    ("glob", "", "malformed-call"),
    ("grep", "", "malformed-call"),
    ("grep", String(repeating: "a", count: 501), "too-large"),
    ("bash", "", "malformed-call"),
    ("bash", " \n ", "malformed-call"),
    ("bash", String(repeating: "x", count: 10_001), "too-large"),
    ("read", String(repeating: "a/", count: 600), "too-large"),
    ("edit", (1...51).map { "f\($0).swift" }.joined(separator: ", "), "too-large"),
  ])
  func malformedCallsGetAMessageTheModelCanUse(tool: String, detail: String, rule: String) throws {
    let rejection = try #require(check(tool, detail), "\(tool.prefix(20)) \(detail.prefix(20))")
    #expect(rejection.rule == rule)
    // Usable: says what was wrong and what to do, in one or two short sentences, with no raw input dumped back.
    #expect(!rejection.message.isEmpty)
    #expect(rejection.message.count < 300)
    #expect(rejection.message.hasSuffix("."))
    #expect(!rejection.message.contains("\0"))
  }

  @Test func anUnknownToolNamesTheOnesThatExist() throws {
    let rejection = try #require(check("delete_everything", "x"))
    #expect(rejection.message == "The tool \"delete_everything\" is not available here. Use read, glob, grep, list, edit, write or bash.")
  }

  @Test func onlyLookingToolsRunWithoutAsking() {
    #expect(ToolCallCheck.readOnly == ["read", "glob", "grep", "list"])
    #expect(!ToolCallCheck.readOnly.contains("bash"))
    #expect(!ToolCallCheck.readOnly.contains("edit"))
  }
}

@Suite struct ToolCallDecodingTests {
  @Test func aGrepPermissionCarriesItsSearchFolder() {
    let event = AgentEventDecoder.decode(Data(#"{"type":"permission.asked","properties":{"id":"per_2","sessionID":"s","permission":"grep","patterns":["TODO"],"metadata":{"pattern":"TODO","path":"/etc","include":"*.conf"},"always":["*"]}}"#.utf8))
    #expect(event == .permission(.init(id: "per_2", tool: "grep", detail: "TODO", path: "/etc")))
  }

  @Test func aReadPermissionCarriesThePath() {
    let event = AgentEventDecoder.decode(Data(#"{"type":"permission.asked","properties":{"id":"per_3","sessionID":"s","permission":"read","patterns":["../../etc/passwd"],"metadata":{},"always":["*"]}}"#.utf8))
    #expect(event == .permission(.init(id: "per_3", tool: "read", detail: "../../etc/passwd")))
  }

  @Test func malformedEventsAreIgnoredNotFatal() {
    for json in [
      #"{"type":"permission.asked","properties":{"permission":"read"}}"#,
      #"{"type":"permission.asked","properties":{"id":42,"permission":"read"}}"#,
      #"{"type":"permission.asked","properties":{"id":"p","permission":"read","patterns":"not-a-list"}}"#,
      #"{"type":"permission.asked"}"#,
      "",
      "[]",
    ] {
      #expect(AgentEventDecoder.decode(Data(json.utf8)) == nil, "\(json)")
    }
  }
}
