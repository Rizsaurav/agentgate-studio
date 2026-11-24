import Foundation
import IOKit
import Metal

public enum HardwareProbeError: Error, Equatable, CustomStringConvertible {
  case sysctl(String)
  case noGPU
  case disk(String)

  public var description: String {
    switch self {
    case .sysctl(let name): return "Could not read \(name) from the system."
    case .noGPU: return "No Metal GPU was found."
    case .disk(let reason): return "Could not read free disk space: \(reason)"
    }
  }
}

/// Reads the hardware profile of the machine the app runs on.
public enum HardwareProbe {
  /// - Parameter modelsDirectory: where models are stored; free space is read for its volume.
  public static func current(modelsDirectory: URL) throws -> HardwareProfile {
    guard let gpu = MTLCreateSystemDefaultDevice() else { throw HardwareProbeError.noGPU }
    let arm = (try? int("hw.optional.arm64")) == 1
    let cores = try int("hw.ncpu")
    let performance = (try? int("hw.perflevel0.physicalcpu")) ?? cores
    let efficiency = (try? int("hw.perflevel1.physicalcpu")) ?? 0
    let os = ProcessInfo.processInfo.operatingSystemVersion
    return HardwareProfile(
      chip: try string("machdep.cpu.brand_string"),
      architecture: arm ? .appleSilicon : .intel,
      memoryBytes: UInt64(try int("hw.memsize")),
      gpuWorkingSetBytes: gpu.recommendedMaxWorkingSetSize,
      gpuCores: gpuCoreCount(),
      performanceCores: performance,
      efficiencyCores: efficiency,
      freeDiskBytes: try freeDisk(at: modelsDirectory),
      osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    )
  }

  static func int(_ name: String) throws -> Int {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { throw HardwareProbeError.sysctl(name) }
    // Some keys are 32-bit; the unused high bytes stay zero.
    return Int(size == 4 ? Int64(Int32(truncatingIfNeeded: value)) : value)
  }

  static func string(_ name: String) throws -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
      throw HardwareProbeError.sysctl(name)
    }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { throw HardwareProbeError.sysctl(name) }
    return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
  }

  /// Apple GPUs publish their core count in the IORegistry; other GPUs do not, so this is optional.
  static func gpuCoreCount() -> Int? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    let value = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)
    return value?.takeRetainedValue() as? Int
  }

  /// Free space on the volume that holds `url`, using the nearest folder that already exists.
  static func freeDisk(at url: URL) throws -> UInt64 {
    var probe = url
    while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
      probe.deleteLastPathComponent()
    }
    do {
      let values = try probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      guard let free = values.volumeAvailableCapacityForImportantUsage else {
        throw HardwareProbeError.disk("the volume did not report it")
      }
      return UInt64(max(free, 0))
    } catch let error as HardwareProbeError {
      throw error
    } catch {
      throw HardwareProbeError.disk(error.localizedDescription)
    }
  }
}
