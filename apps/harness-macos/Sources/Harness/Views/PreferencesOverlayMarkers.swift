import SwiftUI

struct PreferencesOverlayMarkers: View {
  let themeMode: HarnessThemeMode
  let selectedSection: PreferencesSection
  @Environment(\.harnessTextSizeIndex)
  private var textSizeIndex

  private var preferencesStateLabel: String {
    [
      "mode=\(themeMode.rawValue)",
      "section=\(selectedSection.rawValue)",
      "textSize=\(HarnessTextSize.label(for: textSizeIndex))",
      "controlSize=" +
        "\(HarnessTextSize.controlSizeLabel(at: textSizeIndex))",
      "preferencesChrome=native",
    ].joined(separator: ", ")
  }

  var body: some View {
    if HarnessUITestEnvironment.isEnabled {
      ZStack {
        Color.clear
          .allowsHitTesting(false)
          .accessibilityElement()
          .accessibilityLabel(selectedSection.title)
          .accessibilityIdentifier(HarnessAccessibility.preferencesTitle)
        AccessibilityTextMarker(
          identifier: HarnessAccessibility.preferencesState,
          text: preferencesStateLabel
        )
      }
    }
  }
}
