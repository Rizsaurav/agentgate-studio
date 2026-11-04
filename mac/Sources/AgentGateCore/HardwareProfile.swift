import Foundation

/// What the model planner needs to know about this machine.
public struct HardwareProfile: Sendable, Equatable, Codable {
  public enum Architecture: String, Sendable, Codable {
    case appleSilicon
    case intel
  }

  public var chip: String
  public var architecture: Architecture
  public var memoryBytes: UInt64
  /// The GPU working-set limit macOS recommends (Metal `recommendedMaxWorkingSetSize`).
  public var gpuWorkingSetBytes: UInt64
  public var gpuCores: Int?
  public var performanceCores: Int
  public var efficiencyCores: Int
  public var freeDiskBytes: UInt64
  public var osVersion: String

  public init(
    chip: String, architecture: Architecture, memoryBytes: UInt64, gpuWorkingSetBytes: UInt64,
    gpuCores: Int?, performanceCores: Int, efficiencyCores: Int, freeDiskBytes: UInt64,
    osVersion: String
  ) {
    self.chip = chip
    self.architecture = architecture
    self.memoryBytes = memoryBytes
    self.gpuWorkingSetBytes = gpuWorkingSetBytes
    self.gpuCores = gpuCores
    self.performanceCores = performanceCores
    self.efficiencyCores = efficiencyCores
    self.freeDiskBytes = freeDiskBytes
    self.osVersion = osVersion
  }

  public var modelBudgetBytes: UInt64 {
    MemoryBudget.modelBytes(memory: memoryBytes, gpuWorkingSet: gpuWorkingSetBytes)
  }

  /// One readable line, e.g. "Apple M2 · 16 GB · 210 GB free".
  public var summary: String {
    let gib = Double(MemoryBudget.gib)
    let memory = Int((Double(memoryBytes) / gib).rounded())
    let disk = Int(Double(freeDiskBytes) / gib)
    return "\(chip) · \(memory) GB · \(disk) GB free"
  }

  /// Shown when the model will run on the CPU only.
  public var notice: String? {
    architecture == .intel ? "Intel Mac: models run on the CPU, so answers will be slow." : nil
  }
}
