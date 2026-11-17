import Foundation

/// The results of one run of the tool-calling suite against one model, written to
/// `evals/tools/results/<model>-<quant>.json`.
public struct ToolScoreReport: Codable, Sendable, Equatable {
  public struct Category: Codable, Sendable, Equatable {
    public var passed: Int
    public var total: Int
    public var passRate: Double { total == 0 ? 0 : Double(passed) / Double(total) }
  }

  public var model: String
  public var quant: String
  /// The engine and its pinned version, e.g. "llama.cpp b11765".
  public var engine: String
  /// The commit the suite and app were at.
  public var commit: String
  /// The Mac it ran on: chip and memory, nothing that identifies the user.
  public var hardware: String
  public var date: String
  public var temperature: Double
  public var seed: Int
  public var passed: Int
  public var total: Int
  public var categories: [String: Category]
  public var cases: [CaseOutcome]

  public var passRate: Double { total == 0 ? 0 : Double(passed) / Double(total) }
  /// Cases seen to flip between earlier runs of this model, kept from one results file to the next.
  public var knownFlaky: [String] = []
  /// Cases whose runs disagreed this time, or that flipped between runs before.
  public var flaky: [String] { Set(cases.filter(\.flaky).map(\.id) + knownFlaky).sorted() }

  /// This report with the flake history of `previous` (the last results for the same model and quant)
  /// carried over, plus every case whose result differs from it. Cases no longer in the suite are dropped.
  public func carryingFlakes(from previous: ToolScoreReport?) -> ToolScoreReport {
    guard let previous else { return self }
    let before = Dictionary(previous.cases.map { ($0.id, $0.passed) }, uniquingKeysWith: { a, _ in a })
    let flipped = cases.filter { now in before[now.id].map { $0 != now.passed } ?? false }.map(\.id)
    let current = Set(cases.map(\.id))
    var copy = self
    copy.knownFlaky = Set(previous.knownFlaky + flipped).filter(current.contains).sorted()
    return copy
  }
  public var key: String { "\(model)-\(quant)" }
  public var readiness: Readiness { ToolSuite.readiness(probe: .ready, measured: passRate) }

  public init(
    model: String, quant: String, engine: String, commit: String, hardware: String, date: String,
    temperature: Double, seed: Int, cases: [CaseOutcome]
  ) {
    self.model = model
    self.quant = quant
    self.engine = engine
    self.commit = commit
    self.hardware = hardware
    self.date = date
    self.temperature = temperature
    self.seed = seed
    self.cases = cases
    passed = cases.filter(\.passed).count
    total = cases.count
    var categories: [String: Category] = [:]
    for outcome in cases {
      categories[outcome.category, default: Category(passed: 0, total: 0)].total += 1
      if outcome.passed { categories[outcome.category]!.passed += 1 }
    }
    self.categories = categories
  }

  public func write(to folder: URL) throws -> URL {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("\(key).json")
    try (encoder.encode(self) + Data("\n".utf8)).write(to: url, options: .atomic)
    return url
  }

  /// Every results file in `folder`, sorted by model then quant. A missing folder is no results.
  public static func loadAll(from folder: URL) throws -> [ToolScoreReport] {
    guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .map { url in
        do { return try JSONDecoder().decode(ToolScoreReport.self, from: Data(contentsOf: url)) }
        catch { throw ToolSuiteError.invalid("\(url.lastPathComponent) is not a results file (\(error.localizedDescription))") }
      }
      .sorted { $0.key < $1.key }
  }

  /// Models whose pass rate dropped by more than `margin` from `base` to `head`, one line each.
  /// A model only in `base` is a regression too: deleting its results must not hide a drop.
  public static func regressions(base: [ToolScoreReport], head: [ToolScoreReport], margin: Double = ToolSuite.regressionMargin) -> [String] {
    let now = Dictionary(head.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    return base.compactMap { old in
      guard let new = now[old.key] else { return "\(old.key): results were removed (was \(percent(old.passRate)))" }
      // Rounded to whole cases so float noise never decides the gate.
      let drop = ((old.passRate - new.passRate) * 1000).rounded() / 1000
      return drop > margin ? "\(old.key): \(percent(old.passRate)) → \(percent(new.passRate)), more than \(percent(margin)) lower" : nil
    }
  }

  /// The table in docs/MODEL_SCORES.md, generated from the results files so it never drifts from them.
  public static func markdown(_ reports: [ToolScoreReport]) -> String {
    var lines = [
      "# Tool-calling scores",
      "",
      "Generated from `evals/tools/results/` by `swift run --package-path mac agentgate-tooleval report`. Do not edit by hand.",
      "",
      "Each model is run on the bundled engine against the \(reports.first.map { String($0.total) } ?? "")-case suite in `evals/tools/cases/`, at temperature 0 with a fixed seed. A case passes when the calls the model makes (names and arguments) or its refusal to call match what the case expects; prose is never graded. A model needs \(percent(ToolSuite.readyPassRate)) to be offered as **Ready** for agent sessions; below that it is **Chat only**.",
      "",
    ]
    if reports.isEmpty { return (lines + ["No results yet.", ""]).joined(separator: "\n") }
    lines.insert("Each case runs \(reports[0].cases.first?.runs ?? 0) times and passes on a majority. The engine is not bit-for-bit repeatable even at temperature 0, so a case whose runs disagree is listed as flaky below.", at: lines.count - 1)
    lines.insert("", at: lines.count - 1)
    let header = ["Model", "Quant", "Pass rate", "Readiness"] + ToolSuite.categories + ["Engine", "Mac", "Date", "Commit"]
    lines.append("| " + header.joined(separator: " | ") + " |")
    lines.append("|" + String(repeating: " --- |", count: header.count))
    for r in reports {
      let cells = [r.model, r.quant, percent(r.passRate), r.readiness == .ready ? "Ready" : "Chat only"]
        + ToolSuite.categories.map { c in r.categories[c].map { "\($0.passed)/\($0.total)" } ?? "–" }
        + [r.engine, r.hardware, r.date, "`\(r.commit)`"]
      lines.append("| " + cells.joined(separator: " | ") + " |")
    }
    lines += ["", "## Flaky cases", ""]
    for r in reports {
      lines.append("- \(r.key): \(r.flaky.isEmpty ? "none" : r.flaky.map { "`\($0)`" }.joined(separator: ", "))")
    }
    return (lines + [""]).joined(separator: "\n")
  }

  static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}

/// Runs the suite against an OpenAI-compatible endpoint (the bundled engine), one case at a time.
public struct ToolSuiteRunner: Sendable {
  public static let seed = 42
  public static let temperature = 0.0

  public var baseURL: URL
  public var apiKey: String
  public var model: String
  /// Per request. A case that times out fails; the run goes on.
  public var timeout: TimeInterval = 120

  public init(baseURL: URL, apiKey: String, model: String) {
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.model = model
  }

  public func run(_ suite: ToolSuite, progress: (CaseOutcome) -> Void = { _ in }) async throws -> [CaseOutcome] {
    var outcomes: [CaseOutcome] = []
    for item in suite.cases {
      try Task.checkCancellation()
      let start = Date()
      let reason: String?
      do {
        let (calls, text) = try await ask(item, suite)
        reason = ToolSuite.score(item, calls: calls, text: text)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        reason = "request failed: \(error)"
      }
      let outcome = CaseOutcome(
        id: item.id, category: item.category, runs: 1, passes: reason == nil ? 1 : 0, reason: reason ?? "",
        seconds: (Date().timeIntervalSince(start) * 100).rounded() / 100)
      outcomes.append(outcome)
      progress(outcome)
    }
    return outcomes
  }

  /// Combines runs of the whole suite into one outcome per case, in the first run's order.
  public static func merge(_ runs: [[CaseOutcome]]) -> [CaseOutcome] {
    guard let first = runs.first else { return [] }
    return first.map { head in
      let all = runs.compactMap { run in run.first { $0.id == head.id } }
      let seconds = all.map(\.seconds).reduce(0, +) / Double(all.count)
      return CaseOutcome(
        id: head.id, category: head.category, runs: all.map(\.runs).reduce(0, +), passes: all.map(\.passes).reduce(0, +),
        reason: all.first { !$0.reason.isEmpty }?.reason ?? "", seconds: (seconds * 100).rounded() / 100)
    }
  }

  /// Sends one case and returns the calls made and the reply text.
  func ask(_ item: ToolCase, _ suite: ToolSuite) async throws -> ([MadeCall], String) {
    let payload: [String: Any] = [
      "model": model, "temperature": Self.temperature, "seed": Self.seed, "max_tokens": 512,
      "messages": item.messages.map(\.foundation),
      "tools": item.tools.compactMap { suite.tools[$0]?.foundation },
      "tool_choice": "auto",
      // Each case starts from an empty cache, so its result does not depend on the case before it.
      "cache_prompt": false,
      // Thinking models (Qwen3) answer directly, as they do in agent sessions on small Macs.
      "chat_template_kwargs": ["enable_thinking": false],
    ]
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"), timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    // llama-server answers 500 when it cannot parse the model's tool call: that is the model's failure.
    if status == 500, let body = String(data: data.prefix(300), encoding: .utf8), body.localizedCaseInsensitiveContains("pars") {
      return ([MadeCall(name: "unparseable", arguments: nil)], "")
    }
    guard status == 200 else { throw VerifyError.noReply("HTTP \(status)") }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else {
      throw VerifyError.noReply("unexpected response shape")
    }
    return Self.parse(message)
  }

  /// The calls and text in one chat-completion message. Arguments that are not a JSON object are kept as nil.
  static func parse(_ message: [String: Any]) -> ([MadeCall], String) {
    let calls = (message["tool_calls"] as? [[String: Any]] ?? []).map { call -> MadeCall in
      let function = call["function"] as? [String: Any] ?? [:]
      let name = function["name"] as? String ?? ""
      let raw = function["arguments"]
      let object: Any? = (raw as? String).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? raw
      guard let fields = object as? [String: Any] else { return MadeCall(name: name, arguments: nil) }
      return MadeCall(name: name, arguments: fields.mapValues(JSONValue.init(foundation:)))
    }
    return (calls, message["content"] as? String ?? "")
  }
}
