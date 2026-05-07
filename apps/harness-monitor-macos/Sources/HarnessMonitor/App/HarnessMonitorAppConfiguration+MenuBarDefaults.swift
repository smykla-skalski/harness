import Foundation
import HarnessMonitorUIPreviewable

extension HarnessMonitorAppConfiguration {
  static func applyMenuBarUITestDefaults() {
    UserDefaults.standard.set(
      HarnessMonitorMenuBarDefaults.stateColorVariantsEnabledDefault,
      forKey: HarnessMonitorMenuBarDefaults.stateColorVariantsEnabledKey
    )
  }
}
