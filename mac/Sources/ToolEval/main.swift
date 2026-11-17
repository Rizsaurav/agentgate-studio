import AgentGateCore
import Foundation

// agentgate-tooleval: runs the tool-calling reliability suite (evals/tools) against catalog models
// on the bundled engine, writes the results, regenerates docs/MODEL_SCORES.md and gates regressions.
// Run from the repository root. Needs no network and no cloud key once the model file is on disk.

let usage = """
  Usage (from the repository root):
    agentgate-tooleval run --model <catalog id> --gguf <file.gguf>   Score one model file.
    agentgate-tooleval run --all                                     Score every model installed in the app.
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
  return profile.label
}

/// Fresh engine loads per model. Results vary a little between loads, never within one; see `CaseOutcome`.
let loads = 3

/// Runs the suite on `loads` fresh loads of `file`, writes the merged results and returns them.
func score(model: CatalogModel, quant: String, file: URL, suite: ToolSuite) async throws -> ToolScoreReport {
  let engine = engineDirectory()
  // A fixed, modest context so every model is measured the same way; the long-output cases fit in it.
  let config = RuntimeConfig(
    context: 16_384, gpuLayers: 999, kvCacheType: ModelPlanner.kvCacheType(model), flashAttention: true,
    threads: max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
  var runs: [[CaseOutcome]] = []
  for load in 1...loads {
    print("\(model.id) \(quant): load \(load) of \(loads) on \(engineName(engine))…")
    let runtime = try await LlamaRuntime.start(model: file, alias: model.id, config: config, binaries: engine)
    defer { runtime.stop() }
    let runner = ToolSuiteRunner(baseURL: runtime.baseURL, apiKey: runtime.apiKey, model: model.id)
    runs.append(try await runner.run(suite))
  }
  let outcomes = ToolSuiteRunner.merge(runs)
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
    if args.contains("--all") {
      let installed = try ModelStore().list()
      guard !installed.isEmpty else { throw Failure(description: "No models are installed in the app. Install one, or use --model with --gguf.") }
      for item in installed {
        guard let model = catalog.model(item.id) else { print("skipping \(item.id): not in the catalog"); continue }
        _ = try await score(model: model, quant: item.quant.rawValue, file: ModelStore().fileURL(item), suite: suite)
      }
    } else {
      guard let id = option("--model", in: args), let path = option("--gguf", in: args) else { throw Failure(description: usage) }
      guard let model = catalog.model(id) else { throw Failure(description: "\(id) is not in the catalog.") }
      let file = URL(fileURLWithPath: path)
      guard let entry = model.gguf.files.first(where: { $0.file == file.lastPathComponent }) else {
        throw Failure(description: "\(file.lastPathComponent) is not a file the catalog lists for \(id).")
      }
      _ = try await score(model: model, quant: entry.quant.rawValue, file: file, suite: suite)
    }
    try writeReport()
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
