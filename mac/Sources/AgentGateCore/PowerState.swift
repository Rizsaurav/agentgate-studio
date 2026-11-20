import Foundation
import IOKit.ps

public enum PowerState {
  /// True on battery, false on power, nil when macOS does not say (a desktop Mac, or the query failed).
  public static func onBattery() -> Bool? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return nil }
    return type == kIOPMBatteryPowerKey
  }
}
