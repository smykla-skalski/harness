import Foundation
import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

func perfVisualSettingsStateFields() -> [String] {
  let defaults = UserDefaults.standard
  let backdrop =
    defaults.string(forKey: HarnessMonitorBackdropDefaults.modeKey)
    ?? HarnessMonitorBackdropMode.none.rawValue
  let shortcutOverlays = perfBoolLabel(
    defaults.bool(forKey: SessionWindowKeyboardShortcutOverlaySettings.storageKey)
  )
  let titleBlur = perfBoolLabel(
    defaults.bool(forKey: HarnessMonitorSessionTitleBlurDefaults.enabledKey)
  )
  let menuBarStateColors = perfBoolLabel(
    defaults.bool(forKey: HarnessMonitorMenuBarDefaults.stateColorVariantsEnabledKey)
  )
  return [
    "backdrop=\(backdrop)",
    "shortcutOverlays=\(shortcutOverlays)",
    "titleBlur=\(titleBlur)",
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
