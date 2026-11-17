import Foundation

/// How the harness treats one model (#79), generated into the catalog by `build_catalog.py`, never typed by
/// the user: the tool-call format its chat template uses, whether thinking is switched off, sampler settings
/// measured with the tool-calling suite, the system prompt variant, and its known weaknesses.
public struct CapabilityProfile: Codable, Sendable, Equatable {
  public enum PromptVariant: String, Codable, Sendable {
    /// For small models: short instructions, so more of the context is left for the task.
    case compact
    case full
  }

  public struct Sampler: Codable, Sendable, Equatable {
    public var temperature: Double
    public var topP: Double?
    /// The tool-calling pass rate this setting reached, from `evals/tools/sampler/`.
    public var passRate: Double
    public var measured: String
    public var engine: String
  }

  /// hermes, llama3-json, mistral, harmony, phi, or none: read from the model's chat template.
  public var toolCallFormat: String
  /// False when the template has a thinking switch the app turns off (Qwen3); nil when there is none.
  public var thinking: Bool?
  /// Nil until measured; the engine's defaults apply until then.
  public var sampler: Sampler?
  public var promptVariant: PromptVariant
  /// Short sentences for the model's tooltip, from the categories it fails in the suite.
  public var knownIssues: [String]

  public static let formats: Set<String> = ["hermes", "llama3-json", "mistral", "harmony", "phi", "none"]

  func validate(_ id: String) throws {
    guard Self.formats.contains(toolCallFormat) else { throw CatalogError.invalid("\(id) has an unknown tool-call format") }
    if let s = sampler {
      guard (0...2).contains(s.temperature), (s.topP ?? 1) > 0, (s.topP ?? 1) <= 1, (0...1).contains(s.passRate),
            s.measured.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil, !s.engine.isEmpty else {
        throw CatalogError.invalid("\(id) has a bad sampler profile")
      }
    }
    guard knownIssues.count <= 10, knownIssues.allSatisfy({ !$0.isEmpty && $0.count <= 200 }) else {
      throw CatalogError.invalid("\(id) has bad known issues")
    }
  }

  /// Applies the profile to a chat request for the local engine. Values the caller set itself are kept:
  /// the profile fills in what the request leaves open, it never overrides an explicit choice.
  public func apply(to body: inout [String: Any]) {
    if let sampler {
      if body["temperature"] == nil { body["temperature"] = sampler.temperature }
      if let topP = sampler.topP, body["top_p"] == nil { body["top_p"] = topP }
    }
    if thinking == false {
      var kwargs = body["chat_template_kwargs"] as? [String: Any] ?? [:]
      if kwargs["enable_thinking"] == nil { kwargs["enable_thinking"] = false }
      body["chat_template_kwargs"] = kwargs
    }
  }

  /// One line for the session details.
  public var summary: String {
    var parts = ["tool calls: \(toolCallFormat)", "prompt: \(promptVariant.rawValue)"]
    if thinking == false { parts.append("thinking off") }
    if let s = sampler {
      parts.append("temperature \(s.temperature)" + (s.topP.map { ", top-p \($0)" } ?? "") + " (measured \(s.measured))")
    } else {
      parts.append("sampler: engine defaults (not measured)")
    }
    return parts.joined(separator: " · ")
  }

  /// The harness's instructions for models given the compact variant. The full variant is the harness's own.
  public static let compactPrompt = """
    You are a coding agent working in the user's project folder. Use the tools to look before you act: \
    read files, search, run commands. Make the smallest change that does what was asked, then run the \
    project's tests if it has them. Paths are relative to the project. Call one tool at a time and wait for \
    its result. If a tool fails, read the error and try again differently. When you are done, say in one or \
    two sentences what you changed.
    """
}
