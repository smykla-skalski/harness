import SwiftUI

struct PreferencesOverlayMarkers: View {
  let title: String
  let preferencesAccessibilityValue: String

  var body: some View {
    ZStack {
      Color.clear
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityIdentifier(HarnessAccessibility.preferencesTitle)
      AccessibilityTextMarker(
        identifier: HarnessAccessibility.preferencesState,
        text: preferencesAccessibilityValue
      )
    }
  }
}
