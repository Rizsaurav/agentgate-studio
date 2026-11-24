import Foundation

public enum RuntimeError: Error, Equatable, CustomStringConvertible {
  case missingBinary(String)
  case outOfMemory
  case exited(code: Int32, logTail: String)
  case loadTimedOut
  case noFreePort

  public var description: String {
    switch self {
    case .missingBinary(let path): "The bundled model engine is missing (\(path))."
    case .outOfMemory: "The model did not fit in memory."
    case .exited(let code, _): "The model engine stopped unexpectedly (exit code \(code))."
    case .loadTimedOut: "The model took too long to load."
    case .noFreePort: "No free local port was found for the model engine."
    }
  }
}

/// How a model is run, written to its manifest so a load is reproducible.
public struct RuntimeConfig: Codable, Sendable, Equatable {
  public var context: Int
  public var gpuLayers: Int
  public var kvCacheType: String
  public var flashAttention: Bool
  public var threads: Int

  public static func `for`(_ plan: ModelPlan, profile: HardwareProfile, kvCacheType: String = "q8_0") -> RuntimeConfig {
    RuntimeConfig(
      context: plan.context,
      // Apple Silicon shares memory with the GPU, so every layer goes there.
      gpuLayers: profile.architecture == .appleSilicon ? 999 : 0,
      kvCacheType: kvCacheType,
      flashAttention: true,
      threads: max(1, profile.performanceCores))
  }
}

/// One running llama-server, listening on 127.0.0.1 with a per-launch API key.
public final class LlamaRuntime: @unchecked Sendable {
  public let baseURL: URL
  public let apiKey: String
  public let alias: String
  private let process: Process
  private let log: LogTail
  private let output: FileHandle?

  /// Where the bundled engine lives: the app's Resources, or `AGENTGATE_LLAMA_DIR` when run from source.
  public static func binaryDirectory() -> URL? {
    if let dir = ProcessInfo.processInfo.environment["AGENTGATE_LLAMA_DIR"] { return URL(fileURLWithPath: dir) }
    return Bundle.main.resourceURL?.appendingPathComponent("runtime/llama")
  }

  private init(baseURL: URL, apiKey: String, alias: String, process: Process, log: LogTail, output: FileHandle?) {
    self.output = output
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.alias = alias
    self.process = process
    self.log = log
  }

  /// Starts the engine and waits until the model is loaded and answering health checks.
  ///
  /// The port is chosen just before the engine binds it, so another process can take it in between.
  /// When the engine reports that, it is started again on a new port, at most three times in all.
  public static func start(
    model: URL, alias: String, config: RuntimeConfig, binaries: URL? = binaryDirectory(),
    loadTimeout: TimeInterval = 300
  ) async throws -> LlamaRuntime {
    var attempt = 1
    while true {
      do {
        return try await startOnce(model: model, alias: alias, config: config, binaries: binaries, loadTimeout: loadTimeout)
      } catch RuntimeError.exited(let code, let tail) where attempt < 3 && tail.contains("couldn't bind") {
        _ = code
        attempt += 1
      }
    }
  }

  static func startOnce(
    model: URL, alias: String, config: RuntimeConfig, binaries: URL?, loadTimeout: TimeInterval
  ) async throws -> LlamaRuntime {
    guard let server = binaries?.appendingPathComponent("llama-server"),
          FileManager.default.isExecutableFile(atPath: server.path) else {
      throw RuntimeError.missingBinary(binaries?.path ?? "no runtime directory")
    }
    let port = try freePort()
    let key = UUID().uuidString
    let process = Process()
    process.executableURL = server
    process.arguments = [
      "-m", model.path, "--alias", alias, "--host", "127.0.0.1", "--port", String(port),
      "-c", String(config.context), "-ngl", String(config.gpuLayers), "-t", String(config.threads),
      "-fa", config.flashAttention ? "on" : "off", "-ctk", config.kvCacheType, "-ctv", config.kvCacheType,
      // The planner already sized everything; the engine must not change it silently.
      "--jinja", "-np", "1", "--fit", "off",
    ]
    // The key reaches the engine through its environment, never the process list.
    let inherited = ProcessInfo.processInfo.environment.filter { ["HOME", "TMPDIR"].contains($0.key) }
    process.environment = inherited.merging(["LLAMA_API_KEY": key]) { $1 }
    let log = LogTail()
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      // Empty data means the engine closed its output. The handler is called again at once, forever,
      // unless it is removed: that spun a CPU core and could stall stop().
      if data.isEmpty { handle.readabilityHandler = nil } else { log.append(data) }
    }
    try process.run()
    try? EngineRegistry().record(process.processIdentifier)
    let runtime = LlamaRuntime(
      baseURL: URL(string: "http://127.0.0.1:\(port)")!, apiKey: key, alias: alias, process: process, log: log,
      output: pipe.fileHandleForReading)
    do {
      try await runtime.waitUntilHealthy(timeout: loadTimeout)
    } catch {
      runtime.stop()
      throw error
    }
    return runtime
  }

  public var isRunning: Bool { process.isRunning }

  public var processIdentifier: Int32 { process.processIdentifier }

  /// The last lines the engine printed, for the repair assistant.
  public var logTail: String { log.text }

  public func stop() {
    defer {
      output?.readabilityHandler = nil
      EngineRegistry().forget(process.processIdentifier)
    }
    guard process.isRunning else { return }
    process.terminate()
    var deadline = Date().addingTimeInterval(5)
    while process.isRunning, Date() < deadline { usleep(50_000) }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
      // Polled, not waitUntilExit(): that one blocks for as long as the process lingers.
      deadline = Date().addingTimeInterval(5)
      while process.isRunning, Date() < deadline { usleep(50_000) }
    }
  }

  deinit { stop() }

  private func waitUntilHealthy(timeout: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    var request = URLRequest(url: baseURL.appendingPathComponent("health"), timeoutInterval: 2)
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    while Date() < deadline {
      try Task.checkCancellation()
      if !process.isRunning { throw exitError() }
      // Metal can run out of memory while the server keeps answering health checks.
      if outOfMemory { throw RuntimeError.outOfMemory }
      // 503 while loading, 200 once ready; a refused connection means it has not bound yet.
      if let (_, response) = try? await URLSession.shared.data(for: request),
         (response as? HTTPURLResponse)?.statusCode == 200 {
        if outOfMemory { throw RuntimeError.outOfMemory }
        return
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    throw RuntimeError.loadTimedOut
  }

  static let outOfMemoryMarkers = [
    "failed to allocate", "out of memory", "insufficient memory", "kIOGPUCommandBufferCallbackErrorOutOfMemory",
  ]

  /// True once the engine has reported a memory failure, whether or not it is still running.
  public var outOfMemory: Bool {
    let tail = log.text
    return Self.outOfMemoryMarkers.contains { tail.localizedCaseInsensitiveContains($0) }
  }

  func exitError() -> RuntimeError {
    // The process has already ended; give its last output a moment to arrive.
    usleep(100_000)
    return outOfMemory ? .outOfMemory : .exited(code: process.terminationStatus, logTail: log.text)
  }

  public static func freePort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw RuntimeError.noFreePort }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
      }
    }
    guard bound else { throw RuntimeError.noFreePort }
    return Int(UInt16(bigEndian: addr.sin_port))
  }
}

/// Keeps the last 64 KB the engine printed; nothing is written to disk.
final class LogTail: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()
  private let limit = 64 * 1024

  func append(_ chunk: Data) {
    lock.withLock {
      data.append(chunk)
      if data.count > limit { data = data.suffix(limit) }
    }
  }

  var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

/// Pid files for running engines, so engines left behind by a crash or a forced quit are
/// stopped on the next launch. Only processes running our bundled llama-server are touched.
public struct EngineRegistry: Sendable {
  public let folder: URL

  public init(folder: URL = AppPaths.support.appendingPathComponent("engines", isDirectory: true)) {
    self.folder = folder
  }

  func record(_ pid: Int32) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data().write(to: folder.appendingPathComponent(String(pid)))
  }

  func forget(_ pid: Int32) {
    try? FileManager.default.removeItem(at: folder.appendingPathComponent(String(pid)))
  }

  /// Stops recorded engines and agent servers that are still running our bundled binaries.
  /// Returns the pids stopped.
  @discardableResult
  public func reapOrphans(
    binaries: URL? = LlamaRuntime.binaryDirectory(), agent: URL? = AgentServer.binaryDirectory()
  ) -> [Int32] {
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
    let ours = [binaries?.appendingPathComponent("llama-server"), agent?.appendingPathComponent("opencode")]
      .compactMap { $0?.resolvingSymlinksInPath().path }
    var stopped: [Int32] = []
    for entry in entries {
      guard let pid = Int32(entry) else { continue }
      if let path = Self.executablePath(pid), ours.contains(path) {
        kill(pid, SIGTERM)
        stopped.append(pid)
      }
      forget(pid)
    }
    return stopped
  }

  static func executablePath(_ pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return URL(fileURLWithPath: String(decoding: buffer.prefix(Int(length)).map(UInt8.init), as: UTF8.self))
      .resolvingSymlinksInPath().path
  }
}
