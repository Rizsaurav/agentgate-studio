import Foundation

/// Runs git (or another short command) with a deadline and returns what it printed.
enum Git {
  static let executable = "/usr/bin/git"

  /// Output is collected while the command runs, so a long answer (a file list) cannot fill the pipe and stall
  /// it. The deadline is kept on this thread: a timer on a shared queue can fire late when the machine is busy,
  /// and a hung git would then be reported as finished.
  static func run(
    _ args: [String], exe: String = executable, timeout: TimeInterval
  ) -> (output: String?, timedOut: Bool) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: exe)
    process.arguments = args
    process.environment = ProcessInfo.processInfo.environment.filter { ["HOME", "PATH", "TMPDIR", "LANG"].contains($0.key) }
      .merging(["GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"]) { $1 }
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    let output = Collected()
    out.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty { handle.readabilityHandler = nil } else { output.append(data) }
    }
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do { try process.run() } catch { return (nil, false) }
    if exited.wait(timeout: .now() + timeout) == .timedOut, process.isRunning {
      process.terminate()
      process.waitUntilExit()
      out.fileHandleForReading.readabilityHandler = nil
      return (nil, true)
    }
    process.waitUntilExit()
    out.fileHandleForReading.readabilityHandler = nil
    // Whatever arrived between the last read and the exit.
    output.append(out.fileHandleForReading.readDataToEndOfFile())
    guard process.terminationStatus == 0, !output.overflowed else { return (nil, false) }
    return (String(decoding: output.data, as: UTF8.self), false)
  }
}
