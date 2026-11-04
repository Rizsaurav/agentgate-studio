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

  public static func `for`(_ plan: ModelPlan, profile: HardwareProfile) -> RuntimeConfig {
    RuntimeConfig(
      context: plan.context,
      // Apple Silicon shares memory with the GPU, so every layer goes there.
      gpuLayers: profile.architecture == .appleSilicon ? 999 : 0,
      kvCacheType: "q8_0",
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

  /// Where the bundled engine lives: the app's Resources, or `AGENTGATE_LLAMA_DIR` when run from source.
  public static func binaryDirectory() -> URL? {
    if let dir = ProcessInfo.processInfo.environment["AGENTGATE_LLAMA_DIR"] { return URL(fileURLWithPath: dir) }
    return Bundle.main.resourceURL?.appendingPathComponent("runtime/llama")
  }

  private init(baseURL: URL, apiKey: String, alias: String, process: Process, log: LogTail) {
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.alias = alias
    self.process = process
    self.log = log
  }

  /// Starts the engine and waits until the model is loaded and answering health checks.
  public static func start(
    model: URL, alias: String, config: RuntimeConfig, binaries: URL? = binaryDirectory(),
    loadTimeout: TimeInterval = 300
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
    pipe.fileHandleForReading.readabilityHandler = { log.append($0.availableData) }
    try process.run()
    let runtime = LlamaRuntime(
      baseURL: URL(string: "http://127.0.0.1:\(port)")!, apiKey: key, alias: alias, process: process, log: log)
    do {
      try await runtime.waitUntilHealthy(timeout: loadTimeout)
    } catch {
      runtime.stop()
      throw error
    }
    return runtime
  }

  public var isRunning: Bool { process.isRunning }

  /// The last lines the engine printed, for the repair assistant.
  public var logTail: String { log.text }

  public func stop() {
    guard process.isRunning else { return }
    process.terminate()
    let deadline = Date().addingTimeInterval(5)
    while process.isRunning, Date() < deadline { usleep(50_000) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
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
    process.waitUntilExit()
    return outOfMemory ? .outOfMemory : .exited(code: process.terminationStatus, logTail: log.text)
  }

  static func freePort() throws -> Int {
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
