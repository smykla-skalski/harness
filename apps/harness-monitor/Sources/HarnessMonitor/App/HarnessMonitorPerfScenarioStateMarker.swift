import Foundation
import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

func perfVisualSettingsStateFields() -> [String] {
  let defaults = UserDefaults.standard
  let backdrop =
    defaults.string(forKey: HarnessMonitorBackdropDefaults.modeKey)
    ?? HarnessMonitorBackdropMode.none.rawValue
  let menuBarStateColors = perfBoolLabel(
    defaults.bool(forKey: HarnessMonitorMenuBarDefaults.stateColorVariantsEnabledKey)
  )
  return [
    "backdrop=\(backdrop)",
    "menuBarStateColors=\(menuBarStateColors)",
  ]
}

func perfBoolLabel(_ value: Bool) -> String {
  value ? "enabled" : "disabled"
}

struct PerfScenarioStateMarker: ViewModifier {
  let text: String?

  @ViewBuilder
  func body(content: Content) -> some View {
    if let text {
      content.overlay {
        AccessibilityTextMarker(
          identifier: HarnessMonitorAccessibility.perfScenarioState,
          text: text
        )
      }
    } else {
      content
    }
  }
}
