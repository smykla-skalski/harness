import Foundation
import HarnessMonitorUIPreviewable

extension HarnessMonitorAppConfiguration {
  static func applyMenuBarUITestDefaults(stateColorVariantsEnabled: Bool) {
    UserDefaults.standard.set(
      stateColorVariantsEnabled,
      forKey: HarnessMonitorMenuBarDefaults.stateColorVariantsEnabledKey
    )
  }
}
