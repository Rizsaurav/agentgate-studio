import Foundation

/// What one installed model really does on one Mac: speed and a small tool-calling check, measured on
/// the bundled engine. Used instead of size-based estimates wherever it exists (#109).
public struct MeasuredProfile: Codable, Sendable, Equatable {
  /// Which Mac it was measured on (`HardwareProfile.label`): a models folder moved to another Mac is re-measured.
  public var mac: String
  public var measuredAt: Date
  /// Generation speed.
  public var tokensPerSecond: Double
  /// Seconds from sending a short prompt to the first word of the answer.
  public var timeToFirstToken: Double
  public var toolChecksPassed: Int
  public var toolChecksTotal: Int

  /// Whether the tool check reached the same bar as the full suite (`ToolSuite.readyPassRate`).
  public var callsTools: Bool {
    toolChecksTotal > 0
      && ToolSuite.readiness(probe: .ready, measured: Double(toolChecksPassed) / Double(toolChecksTotal)) == .ready
  }

  /// One line for the Models page.
  public var summary: String {
    let speed = tokensPerSecond >= 10 ? String(Int(tokensPerSecond.rounded())) : String(format: "%.1f", tokensPerSecond)
    let first = timeToFirstToken < 1 ? "\(max(10, Int((timeToFirstToken * 1000).rounded()))) ms" : String(format: "%.1f s", timeToFirstToken)
    return "\(speed) tokens/s · first word in \(first) · tools \(toolChecksPassed)/\(toolChecksTotal)"
  }
}

extension HardwareProfile {
  /// Chip and memory, e.g. "Apple M2, 8 GB". Nothing that identifies the user.
  public var label: String { "\(chip), \(memoryBytes >> 30) GB" }
}

public enum MeasureError: Error, Equatable, CustomStringConvertible {
  case noAnswer(String)

  public var description: String {
    switch self {
    case .noAnswer(let detail): "The model could not be measured: \(detail)."
    }
  }
}

/// Measures a model that is loaded on the bundled engine. Takes a few seconds on a small model.
public struct ModelMeasurer: Sendable {
  public var baseURL: URL
  public var apiKey: String
  public var model: String
  public var timeout: TimeInterval = 120

  public init(baseURL: URL, apiKey: String, model: String) {
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.model = model
  }

  public func measure(on mac: String, now: Date = Date()) async throws -> MeasuredProfile {
    let (firstToken, tokensPerSecond) = try await speed()
    var runner = ToolSuiteRunner(baseURL: baseURL, apiKey: apiKey, model: model)
    runner.timeout = timeout
    let outcomes = try await runner.run(try Self.toolCheck())
    return MeasuredProfile(
      mac: mac, measuredAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)),
      tokensPerSecond: (tokensPerSecond * 10).rounded() / 10, timeToFirstToken: (firstToken * 100).rounded() / 100,
      toolChecksPassed: outcomes.filter(\.passed).count, toolChecksTotal: outcomes.count)
  }

  /// Streams a fixed answer and times it. Speed is the engine's own count when it reports one.
  func speed() async throws -> (firstToken: Double, tokensPerSecond: Double) {
    let payload: [String: Any] = [
      "model": model, "stream": true, "temperature": 0, "seed": ToolSuiteRunner.seed, "max_tokens": 128,
      "cache_prompt": false, "chat_template_kwargs": ["enable_thinking": false],
      "messages": [["role": "user", "content": "Describe the sea in one paragraph of about 100 words."]],
    ]
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"), timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
    let start = Date()
    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw MeasureError.noAnswer("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
    }
    var first: Date?
    var last = start
    var chunks = 0
    var reported: Double?
    for try await line in bytes.lines {
      guard line.hasPrefix("data: ") else { continue }
      let body = line.dropFirst(6)
      if body == "[DONE]" { break }
      guard let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else { continue }
      if let timings = json["timings"] as? [String: Any], let perSecond = timings["predicted_per_second"] as? Double, perSecond > 0 {
        reported = perSecond
      }
      let delta = (json["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any]
      if let text = delta?["content"] as? String, !text.isEmpty {
        first = first ?? Date()
        last = Date()
        chunks += 1
      }
    }
    guard let first, chunks > 0 else { throw MeasureError.noAnswer("no text came back") }
    let generating = last.timeIntervalSince(first)
    // Without the engine's count, one streamed chunk is one token.
    let perSecond = reported ?? (chunks > 1 && generating > 0 ? Double(chunks - 1) / generating : 0)
    return (first.timeIntervalSince(start), perSecond)
  }

  /// Five cases from the full suite (evals/tools), one per kind of mistake small models make most.
  /// Built in, because the app does not ship the evaluation folder.
  static func toolCheck() throws -> ToolSuite {
    let decoder = JSONDecoder()
    let suite = ToolSuite(
      tools: try decoder.decode([String: JSONValue].self, from: Data(toolsJSON.utf8)),
      cases: try decoder.decode([ToolCase].self, from: Data(casesJSON.utf8)))
    for item in suite.cases { try item.validate(knownTools: Set(suite.tools.keys)) }
    return suite
  }

  static let toolsJSON = #"""
    {
      "get_weather": {"type": "function", "function": {"name": "get_weather", "description": "Current weather for a city.",
        "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}},
      "get_stock_price": {"type": "function", "function": {"name": "get_stock_price", "description": "Latest price of a stock by ticker symbol.",
        "parameters": {"type": "object", "properties": {"symbol": {"type": "string"}}, "required": ["symbol"]}}},
      "convert_currency": {"type": "function", "function": {"name": "convert_currency", "description": "Convert an amount between currencies.",
        "parameters": {"type": "object", "properties": {"amount": {"type": "number"}, "from": {"type": "string"}, "to": {"type": "string"}},
        "required": ["amount", "from", "to"]}}}
    }
    """#

  static let casesJSON = #"""
    [
      {"id": "single-weather", "category": "single", "description": "One tool, one argument.", "tools": ["get_weather"],
       "messages": [{"role": "user", "content": "What is the weather in Paris right now?"}],
       "expect": {"calls": [{"name": "get_weather", "arguments": {"city": {"contains": "paris"}}}]}},
      {"id": "selection-stock-among-three", "category": "selection", "description": "Only one of three tools fits.",
       "tools": ["get_weather", "get_stock_price", "convert_currency"],
       "messages": [{"role": "user", "content": "What is MSFT trading at?"}],
       "expect": {"calls": [{"name": "get_stock_price", "arguments": {"symbol": {"equals": "MSFT"}}}]}},
      {"id": "parallel-two-stocks", "category": "parallel", "description": "Two calls to one tool.", "tools": ["get_stock_price"],
       "messages": [{"role": "user", "content": "Get the prices of AAPL and GOOG."}],
       "expect": {"calls": [{"name": "get_stock_price", "arguments": {"symbol": {"equals": "AAPL"}}},
                            {"name": "get_stock_price", "arguments": {"symbol": {"equals": "GOOG"}}}]}},
      {"id": "missing-city", "category": "missing-argument", "description": "Asks instead of inventing.", "tools": ["get_weather"],
       "messages": [{"role": "user", "content": "What's the weather like?"}], "expect": {"noCall": true}},
      {"id": "refusal-no-tool-needed", "category": "refusal", "description": "Answers directly.", "tools": ["get_weather", "get_stock_price"],
       "messages": [{"role": "user", "content": "What is 12 times 12?"}], "expect": {"noCall": true, "answerContains": ["144"]}}
    ]
    """#
}

extension ModelStore {
  private func measurementsURL(_ id: String) -> URL { folder(id).appendingPathComponent("measurements.json") }

  /// The measurement of `id` on the Mac labelled `mac`, if there is one.
  public func measurement(_ id: String, on mac: String) throws -> MeasuredProfile? {
    try measurements(id).first { $0.mac == mac }
  }

  /// Keeps one measurement per Mac, replacing the previous one for the same Mac.
  public func saveMeasurement(_ profile: MeasuredProfile, for id: String) throws {
    var all = try measurements(id).filter { $0.mac != profile.mac }
    all.append(profile)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(all).write(to: measurementsURL(id), options: .atomic)
  }

  func measurements(_ id: String) throws -> [MeasuredProfile] {
    let url = measurementsURL(id)
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode([MeasuredProfile].self, from: Data(contentsOf: url))
  }
}
