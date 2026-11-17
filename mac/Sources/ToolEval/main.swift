import AgentGateCore
import Foundation

// agentgate-tooleval: runs the tool-calling reliability suite (evals/tools) against catalog models
// on the bundled engine, writes the results, regenerates docs/MODEL_SCORES.md and gates regressions.
// Run from the repository root. Needs no network and no cloud key once the model file is on disk.

let usage = """
  Usage (from the repository root):
    agentgate-tooleval run --model <catalog id> --gguf <file.gguf>   Score one model file.
    agentgate-tooleval run --all                                     Score every model installed in the app.
      --cpu          run on the CPU only (CI runners without a usable GPU); requests may take up to 15 minutes
      --loads N      fresh engine loads per model (default 3; see CaseOutcome)
      --timeout S    seconds per request (default 120, or 900 with --cpu)
    agentgate-tooleval run --cloud <provider>/<model>                Score a cloud model with the key saved in the app.
  Every request goes through the app's model endpoint (Gateway), as in a session.
    agentgate-tooleval trajectory --model <id> --gguf <file> [--runs N] [--cpu]
    agentgate-tooleval trajectory --cloud <provider>/<model> [--runs N]
                                                                     Run the harness trajectory suite (evals/trajectory).
    agentgate-tooleval trajectory-check --base <results folder>      Fail if a task that passed now fails.
    agentgate-tooleval report                                        Regenerate docs/MODEL_SCORES.md.
    agentgate-tooleval check --base <results folder>                 Fail if a score dropped by more than \(Int(ToolSuite.regressionMargin * 100)) points.

  The engine comes from AGENTGATE_LLAMA_DIR, or mac/dist/runtime/llama (mac/scripts/fetch_runtime.sh).
  """

struct Failure: Error, CustomStringConvertible {
  let description: String
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let suiteFolder = root.appendingPathComponent("evals/tools")
let resultsFolder = suiteFolder.appendingPathComponent("results")
let scoresDoc = root.appendingPathComponent("docs/MODEL_SCORES.md")

func option(_ name: String, in args: [String]) -> String? {
  guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
  return args[i + 1]
}

func engineDirectory() -> URL {
  if let dir = ProcessInfo.processInfo.environment["AGENTGATE_LLAMA_DIR"] { return URL(fileURLWithPath: dir) }
  return root.appendingPathComponent("mac/dist/runtime/llama")
}

func engineName(_ dir: URL) -> String {
  let tag = (try? String(contentsOf: dir.appendingPathComponent(".tag"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
  return "llama.cpp \(tag ?? "unknown")"
}

func commit() -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
  process.arguments = ["rev-parse", "--short", "HEAD"]
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = FileHandle.nullDevice
  guard (try? process.run()) != nil else { return "unknown" }
  process.waitUntilExit()
  let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  return process.terminationStatus == 0 && !text.isEmpty ? text : "unknown"
}

/// Recorded with the results for people reading them; a probe failure is shown as "unknown", not hidden.
func hardware() -> String {
  guard let profile = try? HardwareProbe.current(modelsDirectory: FileManager.default.temporaryDirectory) else { return "unknown" }
  return "\(profile.chip), \(profile.memoryBytes / (1 << 30)) GB"
}

/// How a model is run. Loads: results vary a little between Metal loads, never within one; see `CaseOutcome`.
struct RunOptions {
  var cpuOnly = false
  var loads = 3
  var timeout: TimeInterval = 120

  init(_ args: [String]) throws {
    cpuOnly = args.contains("--cpu")
    if cpuOnly { timeout = 900 }
    if let text = option("--loads", in: args) {
      guard let n = Int(text), (1...10).contains(n) else { throw Failure(description: "--loads takes 1 to 10.") }
      loads = n
    }
    if let text = option("--timeout", in: args) {
      guard let n = TimeInterval(text), n > 0 else { throw Failure(description: "--timeout takes a number of seconds.") }
      timeout = n
    }
  }
}

/// Runs the suite on `loads` fresh loads of `file`, writes the merged results and returns them.
func score(model: CatalogModel, quant: String, file: URL, suite: ToolSuite, options: RunOptions) async throws -> ToolScoreReport {
  let engine = engineDirectory()
  // A fixed, modest context so every model is measured the same way; the long-output cases fit in it.
  let config = RuntimeConfig(
    context: 16_384, gpuLayers: options.cpuOnly ? 0 : 999, kvCacheType: ModelPlanner.kvCacheType(model), flashAttention: true,
    threads: max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
  var runs: [[CaseOutcome]] = []
  for load in 1...options.loads {
    print("\(model.id) \(quant): load \(load) of \(options.loads) on \(engineName(engine))…")
    let runtime = try await LlamaRuntime.start(model: file, alias: model.id, config: config, binaries: engine)
    defer { runtime.stop() }
    // Through the same endpoint the harness uses, so the suite measures what a session gets.
    let gateway = try Gateway(resolve: { id in
      id == model.id ? .local(baseURL: runtime.baseURL, key: runtime.apiKey, model: model.id) : nil
    })
    defer { gateway.stop() }
    var runner = ToolSuiteRunner(baseURL: gateway.baseURL, apiKey: gateway.key, model: model.id)
    runner.timeout = options.timeout
    runs.append(try await runner.run(suite))
  }
  let outcomes = ToolSuiteRunner.merge(runs)
  // A request that failed (timeout, engine error) says nothing about the model: publishing it as a
  // failed case would understate the score, so nothing is written.
  let broken = outcomes.filter { $0.reason.hasPrefix(ToolSuiteRunner.requestFailed) }
  if let first = broken.first {
    throw Failure(description: "\(broken.count) request(s) failed, so no results were written. First: \(first.id): \(first.reason.prefix(200))\nRetry, or raise --timeout.")
  }
  for outcome in outcomes {
    let mark = outcome.flaky ? "FLAKY \(outcome.passes)/\(outcome.runs)" : outcome.passed ? "pass" : "FAIL"
    print("  \(mark) \(outcome.id)\(outcome.reason.isEmpty ? "" : ": \(outcome.reason)")")
  }
  // The last committed results carry the flake history. One that exists but cannot be read stops
  // the run rather than silently losing that history.
  let previousURL = resultsFolder.appendingPathComponent("\(model.id)-\(quant).json")
  let previous = FileManager.default.fileExists(atPath: previousURL.path)
    ? try JSONDecoder().decode(ToolScoreReport.self, from: Data(contentsOf: previousURL)) : nil
  let report = ToolScoreReport(
    model: model.id, quant: quant, engine: engineName(engine), commit: commit(), hardware: hardware(),
    date: String(ISO8601DateFormatter().string(from: Date()).prefix(10)),
    temperature: ToolSuiteRunner.temperature, seed: ToolSuiteRunner.seed, cases: outcomes).carryingFlakes(from: previous)
  let url = try report.write(to: resultsFolder)
  print("\(model.id) \(quant): \(report.passed)/\(report.total) (\(Int((report.passRate * 100).rounded()))%) → \(url.path)")
  return report
}

/// Scores a cloud model through the gateway with the key saved in the app's Keychain. One run: there is
/// no engine to reload, and the provider decides what is repeatable.
func scoreCloud(_ id: String, suite: ToolSuite, options: RunOptions) async throws -> ToolScoreReport {
  guard let (provider, _) = ModelID.parseCloud(id) else { throw Failure(description: "\(id) is not <provider>/<model>.") }
  guard provider.keychain.exists() else { throw Failure(description: "There is no \(provider.name) key. Add one on the app's Profile page.") }
  let gateway = try Gateway(resolve: { requested in requested == id ? ModelID.parseCloud(id).map { .cloud($0.0, model: $0.1) } : nil })
  defer { gateway.stop() }
  print("\(id): scoring through the gateway…")
  var runner = ToolSuiteRunner(baseURL: gateway.baseURL, apiKey: gateway.key, model: id)
  runner.timeout = options.timeout
  let outcomes = try await runner.run(suite)
  let broken = outcomes.filter { $0.reason.hasPrefix(ToolSuiteRunner.requestFailed) }
  if let first = broken.first {
    throw Failure(description: "\(broken.count) request(s) failed, so no results were written. First: \(first.id): \(first.reason.prefix(200))")
  }
  let report = ToolScoreReport(
    model: id, quant: "cloud", engine: provider.name, commit: commit(), hardware: "cloud",
    date: String(ISO8601DateFormatter().string(from: Date()).prefix(10)),
    temperature: ToolSuiteRunner.temperature, seed: ToolSuiteRunner.seed, cases: outcomes)
  let url = try report.write(to: resultsFolder)
  print("\(id): \(report.passed)/\(report.total) → \(url.path)")
  return report
}

let trajectoryFolder = root.appendingPathComponent("evals/trajectory")
let trajectoryResults = trajectoryFolder.appendingPathComponent("results")
let trajectoryDoc = root.appendingPathComponent("docs/TRAJECTORY_SCORES.md")

/// Runs every trajectory task `runs` times, each run on a fresh engine load (or straight to the provider
/// for a cloud model), and writes the merged results with their flake history.
func trajectory(_ args: [String]) async throws {
  let tasks = try TrajectoryTask.loadAll(from: trajectoryFolder)
  let options = try RunOptions(args)
  let runs = try option("--runs", in: args).map { text -> Int in
    guard let n = Int(text), (1...5).contains(n) else { throw Failure(description: "--runs takes 1 to 5.") }
    return n
  } ?? 2
  let harness = ProcessInfo.processInfo.environment["AGENTGATE_OPENCODE_DIR"].map { URL(fileURLWithPath: $0) }
    ?? root.appendingPathComponent("mac/dist/runtime/opencode")
  guard FileManager.default.isExecutableFile(atPath: harness.appendingPathComponent("opencode").path) else {
    throw Failure(description: "The harness is missing: run sh mac/scripts/fetch_opencode.sh, or set AGENTGATE_OPENCODE_DIR.")
  }

  let modelId: String
  let quant: String
  let engineLabel: String
  var start: () async throws -> (Gateway, LlamaRuntime?)
  if let cloud = option("--cloud", in: args) {
    guard let (provider, _) = ModelID.parseCloud(cloud) else { throw Failure(description: "\(cloud) is not <provider>/<model>.") }
    guard provider.keychain.exists() else { throw Failure(description: "There is no \(provider.name) key. Add one on the app's Profile page.") }
    modelId = cloud
    quant = "cloud"
    engineLabel = provider.name
    start = { (try Gateway(resolve: { $0 == cloud ? ModelID.parseCloud(cloud).map { .cloud($0.0, model: $0.1) } : nil }), nil) }
  } else {
    guard let id = option("--model", in: args), let path = option("--gguf", in: args) else { throw Failure(description: usage) }
    guard let model = try Catalog.bundled().model(id) else { throw Failure(description: "\(id) is not in the catalog.") }
    let file = URL(fileURLWithPath: path)
    guard let entry = model.gguf.files.first(where: { $0.file == file.lastPathComponent }) else {
      throw Failure(description: "\(file.lastPathComponent) is not a file the catalog lists for \(id).")
    }
    modelId = id
    quant = entry.quant.rawValue
    engineLabel = engineName(engineDirectory())
    let config = RuntimeConfig(
      context: 32_768, gpuLayers: options.cpuOnly ? 0 : 999, kvCacheType: ModelPlanner.kvCacheType(model), flashAttention: true,
      threads: max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
    start = {
      let runtime = try await LlamaRuntime.start(model: file, alias: id, config: config, binaries: engineDirectory())
      return (try Gateway(resolve: { $0 == id ? .local(baseURL: runtime.baseURL, key: runtime.apiKey, model: id) : nil }), runtime)
    }
  }

  var all: [[CaseOutcome]] = []
  var records: [TrajectoryRecord] = []
  for run in 1...runs {
    print("\(modelId): run \(run) of \(runs)…")
    let (gateway, runtime) = try await start()
    defer { gateway.stop(); runtime?.stop() }
    let runner = TrajectoryRunner(gateway: gateway, model: modelId, context: 32_768, harness: harness)
    var outcomes: [CaseOutcome] = []
    records = []
    for (task, project) in tasks {
      let record = try await runner.run(task, project: project)
      print("  \(record.passed ? "pass" : "FAIL") \(task.id) · \(record.steps.count) steps · \(Int(record.seconds)) s\(record.reason.isEmpty ? "" : " · \(record.reason.prefix(140))")")
      records.append(record)
      outcomes.append(CaseOutcome(id: task.id, category: task.kind, runs: 1, passes: record.passed ? 1 : 0, reason: record.reason, seconds: record.seconds))
    }
    all.append(outcomes)
    gateway.stop()
    runtime?.stop()
  }
  let key = "\(modelId.replacingOccurrences(of: "/", with: "--"))-\(quant)"
  let previousURL = trajectoryResults.appendingPathComponent("\(key).json")
  let previous = FileManager.default.fileExists(atPath: previousURL.path)
    ? try JSONDecoder().decode(TrajectoryReport.self, from: Data(contentsOf: previousURL)).score : nil
  let score = ToolScoreReport(
    model: modelId, quant: quant, engine: engineLabel, commit: commit(), hardware: quant == "cloud" ? "cloud" : hardware(),
    date: String(ISO8601DateFormatter().string(from: Date()).prefix(10)),
    temperature: ToolSuiteRunner.temperature, seed: ToolSuiteRunner.seed, cases: ToolSuiteRunner.merge(all)).carryingFlakes(from: previous)
  let url = try TrajectoryReport(score: score, records: records).write(to: trajectoryResults)
  print("\(modelId): \(score.passed)/\(score.total) tasks → \(url.path)")
  try TrajectoryReport.markdown(try TrajectoryReport.loadAll(from: trajectoryResults)).write(to: trajectoryDoc, atomically: true, encoding: .utf8)
}

func writeReport() throws {
  let reports = try ToolScoreReport.loadAll(from: resultsFolder)
  try ToolScoreReport.markdown(reports).write(to: scoresDoc, atomically: true, encoding: .utf8)
  print("wrote \(scoresDoc.path) (\(reports.count) results)")
}

func main() async throws {
  let args = Array(CommandLine.arguments.dropFirst())
  switch args.first {
  case "run":
    let suite = try ToolSuite.load(from: suiteFolder)
    let catalog = try Catalog.bundled()
    let options = try RunOptions(args)
    if let cloud = option("--cloud", in: args) {
      _ = try await scoreCloud(cloud, suite: suite, options: options)
    } else if args.contains("--all") {
      let installed = try ModelStore().list()
      guard !installed.isEmpty else { throw Failure(description: "No models are installed in the app. Install one, or use --model with --gguf.") }
      for item in installed {
        guard let model = catalog.model(item.id) else { print("skipping \(item.id): not in the catalog"); continue }
        _ = try await score(model: model, quant: item.quant.rawValue, file: ModelStore().fileURL(item), suite: suite, options: options)
      }
    } else {
      guard let id = option("--model", in: args), let path = option("--gguf", in: args) else { throw Failure(description: usage) }
      guard let model = catalog.model(id) else { throw Failure(description: "\(id) is not in the catalog.") }
      let file = URL(fileURLWithPath: path)
      guard let entry = model.gguf.files.first(where: { $0.file == file.lastPathComponent }) else {
        throw Failure(description: "\(file.lastPathComponent) is not a file the catalog lists for \(id).")
      }
      _ = try await score(model: model, quant: entry.quant.rawValue, file: file, suite: suite, options: options)
    }
    try writeReport()
  case "trajectory":
    try await trajectory(args)
  case "trajectory-report":
    try TrajectoryReport.markdown(try TrajectoryReport.loadAll(from: trajectoryResults)).write(to: trajectoryDoc, atomically: true, encoding: .utf8)
  case "trajectory-check":
    guard let base = option("--base", in: args) else { throw Failure(description: usage) }
    _ = try TrajectoryTask.loadAll(from: trajectoryFolder)
    let regressions = TrajectoryReport.regressions(
      base: try TrajectoryReport.loadAll(from: URL(fileURLWithPath: base)), head: try TrajectoryReport.loadAll(from: trajectoryResults))
    guard regressions.isEmpty else {
      throw Failure(description: "Harness trajectory tasks regressed:\n" + regressions.map { "  " + $0 }.joined(separator: "\n"))
    }
    print("No trajectory task regressed.")
  case "report":
    try writeReport()
  case "check":
    guard let base = option("--base", in: args) else { throw Failure(description: usage) }
    _ = try ToolSuite.load(from: suiteFolder)
    let regressions = ToolScoreReport.regressions(
      base: try ToolScoreReport.loadAll(from: URL(fileURLWithPath: base)), head: try ToolScoreReport.loadAll(from: resultsFolder))
    guard regressions.isEmpty else {
      throw Failure(description: "Tool-calling scores regressed:\n" + regressions.map { "  " + $0 }.joined(separator: "\n"))
    }
    print("No tool-calling score dropped by more than \(Int(ToolSuite.regressionMargin * 100)) points.")
  default:
    throw Failure(description: usage)
  }
}

do {
  try await main()
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
