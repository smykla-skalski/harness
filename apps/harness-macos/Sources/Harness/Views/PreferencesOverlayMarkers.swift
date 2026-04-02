import SwiftUI

struct PreferencesOverlayMarkers: View {
  let themeMode: HarnessThemeMode

  var body: some View {
    if HarnessUITestEnvironment.isEnabled {
      ZStack {
        Color.clear
          .allowsHitTesting(false)
          .accessibilityElement()
          .accessibilityLabel("Settings")
          .accessibilityIdentifier(HarnessAccessibility.preferencesTitle)
        AccessibilityTextMarker(
          identifier: HarnessAccessibility.preferencesState,
          text: "mode=\(themeMode.rawValue), preferencesChrome=native"
        )
      }
    }
  }
}
