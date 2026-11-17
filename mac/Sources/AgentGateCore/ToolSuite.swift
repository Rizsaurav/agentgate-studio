import Foundation

/// Any JSON value. Tool-calling cases carry raw chat messages and tool schemas, which are passed to
/// the engine as written, so they are kept as JSON rather than modelled field by field.
public enum JSONValue: Codable, Sendable, Equatable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null }
    else if let v = try? c.decode(Bool.self) { self = .bool(v) }
    else if let v = try? c.decode(Double.self) { self = .number(v) }
    else if let v = try? c.decode(String.self) { self = .string(v) }
    else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
    else { self = .object(try c.decode([String: JSONValue].self)) }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let v): try c.encode(v)
    case .number(let v): try c.encode(v)
    case .string(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .object(let v): try c.encode(v)
    }
  }

  /// The value as Foundation objects, for `JSONSerialization`.
  public var foundation: Any {
    switch self {
    case .null: NSNull()
    case .bool(let v): v
    case .number(let v): v
    case .string(let v): v
    case .array(let v): v.map(\.foundation)
    case .object(let v): v.mapValues(\.foundation)
    }
  }

  /// Converts what `JSONSerialization` returns. NSNumber booleans stay booleans.
  public init(foundation value: Any) {
    switch value {
    case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): self = .bool(n.boolValue)
    case let n as NSNumber: self = .number(n.doubleValue)
    case let s as String: self = .string(s)
    case let a as [Any]: self = .array(a.map(JSONValue.init(foundation:)))
    case let o as [String: Any]: self = .object(o.mapValues(JSONValue.init(foundation:)))
    default: self = .null
    }
  }
}

/// One expected argument value. Exactly one field is set; see `ToolCase.validate()`.
public struct ArgumentMatch: Codable, Sendable, Equatable {
  /// The value must be exactly this (numbers compare as numbers, so 3 matches 3.0).
  public var equals: JSONValue?
  /// The value must be a string containing this text, ignoring case.
  public var contains: String?
  /// The value must be an object whose listed keys match; other keys are allowed.
  public var object: [String: ArgumentMatch]?
  /// The key must be present, with any value.
  public var present: Bool?

  public init(equals: JSONValue? = nil, contains: String? = nil, object: [String: ArgumentMatch]? = nil, present: Bool? = nil) {
    self.equals = equals
    self.contains = contains
    self.object = object
    self.present = present
  }

  var fieldCount: Int { [equals != nil, contains != nil, object != nil, present != nil].filter { $0 }.count }

  /// Nil when `value` matches, otherwise why not.
  func mismatch(_ value: JSONValue?, at path: String) -> String? {
    guard let value, value != .null else { return "\(path) is missing" }
    if let equals, !Self.same(equals, value) { return "\(path) is \(Self.show(value)), expected \(Self.show(equals))" }
    if let contains {
      guard case .string(let text) = value, text.localizedCaseInsensitiveContains(contains) else {
        return "\(path) is \(Self.show(value)), expected text containing \"\(contains)\""
      }
    }
    if let object {
      guard case .object(let fields) = value else { return "\(path) is not an object" }
      for key in object.keys.sorted() {
        if let reason = object[key]!.mismatch(fields[key], at: "\(path).\(key)") { return reason }
      }
    }
    return nil
  }

  static func same(_ a: JSONValue, _ b: JSONValue) -> Bool {
    switch (a, b) {
    case (.number(let x), .number(let y)): x == y
    case (.string(let x), .string(let y)): x == y
    case (.array(let x), .array(let y)): x.count == y.count && zip(x, y).allSatisfy(same)
    case (.object(let x), .object(let y)): x.keys == y.keys && x.keys.allSatisfy { same(x[$0]!, y[$0]!) }
    default: a == b
    }
  }

  static func show(_ value: JSONValue) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: value.foundation, options: [.fragmentsAllowed, .sortedKeys])) ?? Data()
    return String(decoding: data.prefix(120), as: UTF8.self)
  }
}

/// A call the model is expected to make.
public struct ExpectedCall: Codable, Sendable, Equatable {
  public var name: String
  public var arguments: [String: ArgumentMatch]

  public init(name: String, arguments: [String: ArgumentMatch] = [:]) {
    self.name = name
    self.arguments = arguments
  }
}

/// What a correct answer looks like. Checked on the structure of the reply, never by grading prose.
public struct ToolExpectation: Codable, Sendable, Equatable {
  /// The calls that must be made, in any order unless `ordered` is set. No other calls are allowed.
  public var calls: [ExpectedCall]?
  public var ordered: Bool?
  /// The model must not call any tool: it should answer, ask for what is missing, or refuse.
  public var noCall: Bool?
  /// When `noCall` is set: each of these must appear in the reply text, ignoring case.
  public var answerContains: [String]?

  public init(calls: [ExpectedCall]? = nil, ordered: Bool? = nil, noCall: Bool? = nil, answerContains: [String]? = nil) {
    self.calls = calls
    self.ordered = ordered
    self.noCall = noCall
    self.answerContains = answerContains
  }
}

/// One tool-calling case from `evals/tools/cases/`.
public struct ToolCase: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var category: String
  /// What the case checks, for people reading the results.
  public var description: String
  /// Names of tools from `evals/tools/tools.json` offered to the model.
  public var tools: [String]
  /// Chat messages sent as written: user turns, and for recovery cases earlier assistant calls and tool results.
  public var messages: [JSONValue]
  public var expect: ToolExpectation

  func validate(knownTools: Set<String>) throws {
    func fail(_ reason: String) -> ToolSuiteError { .invalid("case \(id): \(reason)") }
    guard id.wholeMatch(of: /[a-z0-9][a-z0-9\-]{0,63}/) != nil else { throw ToolSuiteError.invalid("bad case id \"\(id)\"") }
    guard ToolSuite.categories.contains(category) else { throw fail("unknown category \(category)") }
    guard !messages.isEmpty else { throw fail("no messages") }
    for tool in tools where !knownTools.contains(tool) { throw fail("unknown tool \(tool)") }
    let hasCalls = !(expect.calls ?? []).isEmpty
    guard hasCalls != (expect.noCall == true) else { throw fail("expect either calls or noCall") }
    for call in expect.calls ?? [] {
      guard tools.contains(call.name) else { throw fail("expects \(call.name), which is not offered") }
      try check(call.arguments, fail)
    }
  }

  private func check(_ arguments: [String: ArgumentMatch], _ fail: (String) -> ToolSuiteError) throws {
    for match in arguments.values {
      guard match.fieldCount == 1 else { throw fail("an argument match must set exactly one of equals, contains, object, present") }
      if let nested = match.object { try check(nested, fail) }
    }
  }
}

/// A call the model made, as returned by the engine.
public struct MadeCall: Sendable, Equatable {
  public var name: String
  /// Nil when the arguments were not a JSON object: a malformed call.
  public var arguments: [String: JSONValue]?

  public init(name: String, arguments: [String: JSONValue]?) {
    self.name = name
    self.arguments = arguments
  }
}

/// One case's result over several runs. Even at temperature 0 with a fixed seed the engine gives
/// slightly different results from one load of a model to the next (it is repeatable within one
/// load), so the suite runs on several fresh loads: a case passes on a majority, and is listed as
/// flaky when the runs disagree, so a flip between two runs is never mistaken for a regression.
public struct CaseOutcome: Codable, Sendable, Equatable {
  public var id: String
  public var category: String
  public var runs: Int
  public var passes: Int
  /// Why the first failing run failed, in one line; empty when every run passed.
  public var reason: String
  /// Mean seconds per run.
  public var seconds: Double

  public init(id: String, category: String, runs: Int, passes: Int, reason: String, seconds: Double) {
    self.id = id
    self.category = category
    self.runs = runs
    self.passes = passes
    self.reason = reason
    self.seconds = seconds
  }

  public var passed: Bool { passes * 2 > runs }
  public var flaky: Bool { passes > 0 && passes < runs }
}

public enum ToolSuiteError: Error, Equatable, CustomStringConvertible {
  case invalid(String)

  public var description: String {
    switch self {
    case .invalid(let reason): "The tool-calling suite is invalid: \(reason)"
    }
  }
}

/// The tool-calling reliability suite: cases, scoring and the rule that turns a score into readiness.
public struct ToolSuite: Sendable {
  /// Every case belongs to one of these. A results file reports a pass rate for each.
  public static let categories = [
    "single", "selection", "multiple", "missing-argument", "nested", "parallel", "recovery", "long-output", "refusal",
  ]
  public static let minimumCases = 40

  /// A model is offered for agent sessions only when it passes at least this share of the suite.
  /// Set from the first measured runs (docs/MODEL_SCORES.md): Qwen3 0.6B scored 69-73% over repeated runs and
  /// Qwen3 1.7B 76-80%, so the bar falls between them. Revisit as more models are measured.
  public static let readyPassRate = 0.75
  /// A pull request may lower a model's pass rate by at most this much before the gate fails.
  public static let regressionMargin = 0.05

  public var tools: [String: JSONValue]
  public var cases: [ToolCase]

  /// Reads `tools.json` and every `cases/*.json` under `folder`, and rejects the suite as a whole if anything is off.
  public static func load(from folder: URL) throws -> ToolSuite {
    let decoder = JSONDecoder()
    let tools: [String: JSONValue]
    do {
      tools = try decoder.decode([String: JSONValue].self, from: Data(contentsOf: folder.appendingPathComponent("tools.json")))
    } catch {
      throw ToolSuiteError.invalid("tools.json could not be read (\(error.localizedDescription))")
    }
    let files = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("cases"), includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    var cases: [ToolCase] = []
    for file in files {
      do {
        cases += try decoder.decode([ToolCase].self, from: Data(contentsOf: file))
      } catch {
        throw ToolSuiteError.invalid("\(file.lastPathComponent) is not a valid list of cases (\(error.localizedDescription))")
      }
    }
    let suite = ToolSuite(tools: tools, cases: cases)
    try suite.validate()
    return suite
  }

  func validate() throws {
    for (name, schema) in tools {
      guard case .object(let fields) = schema, case .object(let function)? = fields["function"],
            function["name"] == .string(name) else {
        throw ToolSuiteError.invalid("tool \(name) is not an OpenAI function definition with that name")
      }
    }
    var seen = Set<String>()
    for item in cases {
      try item.validate(knownTools: Set(tools.keys))
      guard seen.insert(item.id).inserted else { throw ToolSuiteError.invalid("duplicate case id \(item.id)") }
    }
    guard cases.count >= Self.minimumCases else { throw ToolSuiteError.invalid("\(cases.count) cases, at least \(Self.minimumCases) needed") }
    for category in Self.categories where !cases.contains(where: { $0.category == category }) {
      throw ToolSuiteError.invalid("no case in category \(category)")
    }
  }

  /// Nil when the reply is correct for `item`, otherwise why it is not.
  public static func score(_ item: ToolCase, calls: [MadeCall], text: String) -> String? {
    if item.expect.noCall == true {
      if let call = calls.first { return "called \(call.name), expected no tool call" }
      for needle in item.expect.answerContains ?? [] where !text.localizedCaseInsensitiveContains(needle) {
        return "the answer does not mention \"\(needle)\""
      }
      return nil
    }
    let expected = item.expect.calls ?? []
    if calls.isEmpty { return "no tool call, expected \(expected.map(\.name).joined(separator: ", "))" }
    if let bad = calls.first(where: { $0.arguments == nil }) { return "\(bad.name) was called with arguments that are not a JSON object" }
    guard calls.count == expected.count else {
      return "\(calls.count) calls (\(calls.map(\.name).joined(separator: ", "))), expected \(expected.count)"
    }
    if item.expect.ordered == true {
      for (made, wanted) in zip(calls, expected) {
        if let reason = mismatch(made, wanted) { return reason }
      }
      return nil
    }
    // Unordered: every expected call must be matched by a different made call.
    var remaining = calls
    for wanted in expected {
      guard let index = remaining.firstIndex(where: { mismatch($0, wanted) == nil }) else {
        let sameName = remaining.first { $0.name == wanted.name }
        return sameName.flatMap { mismatch($0, wanted) } ?? "no call to \(wanted.name)"
      }
      remaining.remove(at: index)
    }
    return nil
  }

  static func mismatch(_ made: MadeCall, _ wanted: ExpectedCall) -> String? {
    guard made.name == wanted.name else { return "called \(made.name), expected \(wanted.name)" }
    let arguments = made.arguments ?? [:]
    for key in wanted.arguments.keys.sorted() {
      if let reason = wanted.arguments[key]!.mismatch(arguments[key], at: "\(made.name).\(key)") { return reason }
    }
    return nil
  }

  /// Ready for agent sessions only when the install probe passed and, where the suite has measured
  /// the model, its pass rate reaches `readyPassRate`. A model never measured keeps the probe's result.
  public static func readiness(probe: Readiness, measured passRate: Double?) -> Readiness {
    guard probe == .ready else { return .chatOnly }
    guard let passRate else { return .ready }
    return passRate >= readyPassRate ? .ready : .chatOnly
  }
}
