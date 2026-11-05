import Foundation
import Testing

@testable import AgentGateCore

@Suite struct AgentPermissionsTests {
  func blockedRule(_ tool: String, _ role: AgentRole, _ project: ProjectAccess = .full) -> String? {
    if case .block(let rule, _) = AgentPermissions.check(tool: tool, role: role, project: project) { return rule }
    return nil
  }

  @Test(arguments: ProjectAccess.allCases)
  func theSupervisingAgentCannotEditOrRunCommandsInAnyProject(project: ProjectAccess) {
    for tool in ["edit", "write", "patch", "multiedit", "bash"] {
      #expect(blockedRule(tool, .supervisor, project) == "not-allowed-for-agent", "\(tool)")
    }
    #expect(blockedRule("read", .supervisor, project) == nil)
  }

  @Test(arguments: ProjectAccess.allCases)
  func theCodingAgentCannotChangeInstallSettings(project: ProjectAccess) {
    #expect(AgentPermissions.check(.installSettings, role: .coder, project: project)
      == .block(rule: "not-allowed-for-agent",
                reason: "The coder agent may never: change model installs and engine settings."))
    #expect(AgentPermissions.check(.installSettings, role: .supervisor, project: project) == .allow)
  }

  @Test func theRepairAgentOnlyTouchesInstalls() {
    #expect(AgentPermissions.effective(.repair, project: .full) == [.installSettings])
    for tool in ["read", "edit", "bash", "webfetch"] { #expect(blockedRule(tool, .repair) == "not-allowed-for-agent") }
  }

  @Test func aProjectNarrowsTheCodingAgent() {
    #expect(blockedRule("bash", .coder, .full) == nil)
    #expect(blockedRule("edit", .coder, .full) == nil)
    #expect(AgentPermissions.check(.network, role: .coder, project: .noNetwork).isBlocked)
    #expect(blockedRule("bash", .coder, .noNetwork) == nil)
    for tool in ["bash", "edit", "write", "patch", "multiedit"] {
      #expect(blockedRule(tool, .coder, .readOnly) == "not-allowed-in-project", "\(tool)")
    }
    for tool in ["read", "glob", "grep", "list"] { #expect(blockedRule(tool, .coder, .readOnly) == nil) }
  }

  @Test func aProjectNeverWidensARole() {
    for role in AgentRole.allCases {
      for project in ProjectAccess.allCases {
        #expect(AgentPermissions.effective(role, project: project).isSubset(of: AgentPermissions.base(role)))
      }
    }
  }

  @Test func unknownToolsAreRefused() {
    #expect(blockedRule("doom_loop", .coder) == "unknown-tool")
    #expect(blockedRule("", .supervisor) == "unknown-tool")
  }

  @Test func theHarnessIsStartedWithTheProjectsRules() throws {
    func rules(_ access: ProjectAccess) throws -> [String: String] {
      let text = try AgentServer.config(
        engineURL: URL(string: "http://127.0.0.1:1234")!, engineKey: "k", model: "m", context: 8192, access: access)
      let json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
      return try #require(json["permission"] as? [String: String])
    }
    let reads = ["read": "ask", "glob": "ask", "grep": "ask", "list": "ask"]
    #expect(try rules(.full) == reads.merging(
      ["bash": "ask", "edit": "ask", "webfetch": "deny", "external_directory": "deny"]) { a, _ in a })
    #expect(try rules(.noNetwork)["bash"] == "ask")
    #expect(try rules(.readOnly) == reads.merging(
      ["bash": "deny", "edit": "deny", "webfetch": "deny", "external_directory": "deny"]) { a, _ in a })
    #expect(AgentPermissions.sandboxNetwork(.full))
    #expect(!AgentPermissions.sandboxNetwork(.noNetwork))
    #expect(!AgentPermissions.sandboxNetwork(.readOnly))
  }

  @Test func projectsSavedBeforeThisStillLoadAsFull() throws {
    let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"p","createdAt":0}"#
    let project = try JSONDecoder().decode(Project.self, from: Data(old.utf8))
    #expect(project.access == nil && project.effectiveAccess == .full)
    var narrowed = project
    narrowed.access = .readOnly
    let again = try JSONDecoder().decode(Project.self, from: try JSONEncoder().encode(narrowed))
    #expect(again.effectiveAccess == .readOnly)
  }
}
