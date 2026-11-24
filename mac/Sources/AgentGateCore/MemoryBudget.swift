/// How much memory a model (weights plus KV cache) may use on a machine.
///
/// The budget is the smaller of the GPU working-set limit macOS reports and the memory left after
/// macOS and everyday apps, minus what the bundled harness itself needs.
public enum MemoryBudget {
  public static let gib: UInt64 = 1 << 30
  /// Memory the harness, scanner and app need alongside the model.
  public static let harnessReserve: UInt64 = 3 * gib / 2

  /// Memory left for macOS and the user's other apps, by memory class.
  public static func systemReserve(memory: UInt64) -> UInt64 {
    switch memory {
    case ..<(12 * gib): return 7 * gib / 2
    case ..<(20 * gib): return 4 * gib
    case ..<(40 * gib): return 6 * gib
    default: return 8 * gib
    }
  }

  /// Bytes available to one loaded model, or zero when the machine cannot run one.
  public static func modelBytes(memory: UInt64, gpuWorkingSet: UInt64) -> UInt64 {
    let afterSystem = memory > systemReserve(memory: memory) ? memory - systemReserve(memory: memory) : 0
    let ceiling = min(afterSystem, gpuWorkingSet)
    return ceiling > harnessReserve ? ceiling - harnessReserve : 0
  }
}
