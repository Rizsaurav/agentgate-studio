import Foundation
import Testing

@testable import AgentGateCore

/// What the agent may do, and how each choice reaches the harness and the gate.
@Suite struct CapabilityTests {
  func config(_ capabilities: AgentCapabilities, folder: URL? = URL(fileURLWithPath: "/work/proj")) throws -> [String: Any] {
    let text = try AgentServer.config(
      engineURL: URL(string: "http://127.0.0.1:9")!, engineKey: "k", model: "m", context: 32768,
      capabilities: capabilities, folder: folder)
    return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
  }

  @Test func everythingStartsOffSoTheDefaultAgentStaysLean() throws {
    let c = try config(AgentCapabilities())
    let tools = try #require(c["tools"] as? [String: Bool])
    #expect(Set(tools.keys) == Set(AgentServer.optionalTools) && tools.values.allSatisfy { !$0 })
    let permission = try #require(c["permission"] as? [String: String])
    #expect(permission["webfetch"] == "deny" && permission["websearch"] == "deny" && permission["lsp"] == "deny")
    #expect(permission["doom_loop"] == "ask" && permission["external_directory"] == "deny")
    #expect(c["lsp"] as? Bool == false && c["mcp"] == nil && c["skills"] == nil)
  }

  @Test func eachCapabilityTurnsOnItsToolAndTellsTheModelWhenToUseIt() throws {
    var all = AgentCapabilities()
    all.todos = true; all.subagents = true; all.skills = true; all.codeNavigation = true
    all.webFetch = true; all.webSearch = true
    let c = try config(all)
    let tools = try #require(c["tools"] as? [String: Bool])
    #expect(tools == ["question": false])
    let permission = try #require(c["permission"] as? [String: String])
    #expect(permission["webfetch"] == "ask" && permission["websearch"] == "ask" && permission["lsp"] == "ask")
    #expect(c["lsp"] as? Bool == true)
    let skills = try #require(c["skills"] as? [String: [String]])
    #expect(skills["paths"] == ["/work/proj/.agents/skills"])
    let agents = try #require(c["agent"] as? [String: [String: Any]])
    let prompt = try #require(agents[AgentServer.agentName]?["prompt"] as? String)
    for word in ["todowrite", "task tool", "skill tool", "lsp tool", "web"] { #expect(prompt.contains(word)) }
  }

  @Test func thePlanAgentCanLookButNotChangeAnything() throws {
    let agents = try #require(try config(AgentCapabilities())["agent"] as? [String: [String: Any]])
    let plan = try #require(agents[AgentServer.planAgentName])
    #expect(plan["tools"] as? [String: Bool] == ["edit": false, "write": false, "bash": false, "patch": false])
    #expect(plan["permission"] as? [String: String] == ["edit": "deny", "bash": "deny"])
    #expect((plan["prompt"] as? String)?.contains("Do not change anything") == true)
  }

  @Test func mcpServersAreStartedFromTheAppsListOnlyAndEveryToolAsks() throws {
    var capabilities = AgentCapabilities()
    capabilities.mcpServers = [
      .init(name: "memory", command: ["npx", "-y", "@modelcontextprotocol/server-memory"]),
      .init(name: "off", command: ["x"], enabled: false),
      .init(name: "Bad Name", command: ["x"]),
    ]
    let c = try config(capabilities)
    let mcp = try #require(c["mcp"] as? [String: [String: Any]])
    #expect(Array(mcp.keys) == ["memory"])
    #expect(mcp["memory"]?["command"] as? [String] == ["npx", "-y", "@modelcontextprotocol/server-memory"])
    #expect((c["permission"] as? [String: String])?["memory_*"] == "ask")
    #expect(capabilities.isMCPTool("memory_create_entities") && !capabilities.isMCPTool("off_tool"))
  }

  @Test func theHarnessAlwaysIgnoresTheProjectsAndTheHomeFoldersAgentSettings() {
    let env = AgentCapabilities().environment
    for key in ["OPENCODE_DISABLE_PROJECT_CONFIG", "OPENCODE_DISABLE_CLAUDE_CODE", "OPENCODE_DISABLE_EXTERNAL_SKILLS",
                "OPENCODE_DISABLE_MODELS_FETCH", "OPENCODE_DISABLE_LSP_DOWNLOAD"] {
      #expect(env[key] == "1", "\(key) must be set")
    }
    #expect(env["OPENCODE_EXPERIMENTAL_BASH_DEFAULT_TIMEOUT_MS"] == "300000")
    #expect(env["OPENCODE_ENABLE_EXA"] == nil && env["OPENCODE_EXPERIMENTAL_LSP_TOOL"] == nil)
    var on = AgentCapabilities()
    on.webSearch = true; on.codeNavigation = true; on.subagents = true
    #expect(on.environment["OPENCODE_ENABLE_EXA"] == "1" && on.environment["OPENCODE_EXPERIMENTAL_LSP_TOOL"] == "1")
    #expect(on.environment["OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS"] == "1")
  }

  @Test func capabilitiesSurviveASaveAndOlderFilesStillLoad() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("cap-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let store = CapabilityStore(file: file)
    #expect(store.load() == AgentCapabilities())
    var capabilities = AgentCapabilities()
    capabilities.todos = true
    capabilities.mcpServers = [.init(name: "fs", command: ["server"])]
    try store.save(capabilities)
    #expect(store.load() == capabilities)
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    try #"{"todos":true}"#.write(to: file, atomically: true, encoding: .utf8)
    #expect(store.load().todos && !store.load().webFetch)
  }

  @Test func commandLinesSplitLikeAShellForPlainArguments() {
    #expect(CommandLineWords.split("npx -y @scope/server  --root '/a b' \"c d\"") == ["npx", "-y", "@scope/server", "--root", "/a b", "c d"])
    #expect(CommandLineWords.split("   ") == [])
    #expect(CommandLineWords.split("run ''") == ["run", ""])
  }

  @Test func serverNamesAreShortAndSafe() {
    #expect(AgentCapabilities.MCPServer.isValidName("memory-2"))
    for bad in ["", "2fast", "Memory", "a b", "a_b", String(repeating: "a", count: 33)] {
      #expect(!AgentCapabilities.MCPServer.isValidName(bad), "\(bad)")
    }
  }
}

/// The gate for the new tools: web addresses, searches, code lookups and MCP tools.
@Suite struct CapabilityGateTests {
  let folder = URL(fileURLWithPath: "/work/proj")

  func check(_ tool: String, _ detail: String, path: String? = nil, capabilities: AgentCapabilities = AgentCapabilities()) -> String? {
    ToolCallCheck.check(.init(id: "p", tool: tool, detail: detail, path: path), folder: folder, capabilities: capabilities)?.rule
  }

  @Test func aFetchMayReachPublicPagesOnly() {
    #expect(check("webfetch", "https://developer.apple.com/documentation/swift") == nil)
    for blocked in ["http://127.0.0.1:8080/v1/models", "http://localhost:3000", "http://[::1]/", "http://10.0.0.5/admin",
                    "http://192.168.1.1", "http://172.20.0.1", "http://169.254.169.254/latest/meta-data", "http://printer.local",
                    "http://intranet/", "http://100.100.1.1"] {
      #expect(check("webfetch", blocked) == "private-address", "\(blocked)")
    }
    for malformed in ["file:///etc/passwd", "ftp://example.com", "not a url", ""] {
      #expect(check("webfetch", malformed) == "malformed-call", "\(malformed)")
    }
  }

  @Test func searchesNeedAQueryOfSaneLength() {
    #expect(check("websearch", "swift concurrency actors") == nil)
    #expect(check("websearch", "  ") == "malformed-call")
    #expect(check("websearch", String(repeating: "q", count: 501)) == "too-large")
  }

  @Test func codeLookupsStayInsideTheProject() {
    #expect(check("lsp", "/work/proj/Sources/App.swift") == nil)
    #expect(check("lsp", "/etc/hosts") == "outside-project")
    #expect(ToolCallCheck.readOnly.contains("lsp"))
  }

  @Test func mcpToolsPassOnlyForServersTheUserAdded() {
    var capabilities = AgentCapabilities()
    capabilities.mcpServers = [.init(name: "memory", command: ["srv"])]
    #expect(check("memory_read_graph", "", capabilities: capabilities) == nil)
    #expect(check("memory_read_graph", "") == "unknown-tool")
    #expect(check("evil_run", "", capabilities: capabilities) == "unknown-tool")
  }

  @Test func aToDoListArrivesAsAChecklistStep() throws {
    let event = #"{"type":"message.part.updated","properties":{"part":{"id":"prt_t","messageID":"msg_1","type":"tool","tool":"todowrite","callID":"c1","state":{"status":"completed","input":{"todos":[{"content":"Read cart.py","status":"completed","priority":"high","id":"1"},{"content":"Fix subtotal","status":"in_progress","priority":"high","id":"2"},{"content":"Run tests","status":"pending","priority":"medium","id":"3"}]},"output":"[]","title":"2 todos"}}}}"#
    var transcript = Transcript()
    transcript.apply(try #require(AgentEventDecoder.decode(Data(event.utf8))))
    let todos = try #require(transcript.steps.first?.todos)
    #expect(todos.map(\.content) == ["Read cart.py", "Fix subtotal", "Run tests"])
    #expect(todos.map(\.status) == ["completed", "in_progress", "pending"] && todos[0].isDone)
  }
}
