import SwiftUI

struct PreferencesOverlayMarkers: View {
  let themeMode: HarnessMonitorThemeMode
  let selectedSection: PreferencesSection
  @Environment(\.harnessTextSizeIndex)
  private var textSizeIndex

  private var preferencesStateLabel: String {
    [
      "mode=\(themeMode.rawValue)",
      "section=\(selectedSection.rawValue)",
      "textSize=\(HarnessMonitorTextSize.label(for: textSizeIndex))",
      "controlSize=" +
        "\(HarnessMonitorTextSize.controlSizeLabel(at: textSizeIndex))",
      "preferencesChrome=native",
    ].joined(separator: ", ")
  }

  var body: some View {
    if HarnessMonitorUITestEnvironment.isEnabled {
      ZStack {
        Color.clear
          .allowsHitTesting(false)
          .accessibilityElement()
          .accessibilityLabel(selectedSection.title)
          .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesTitle)
        AccessibilityTextMarker(
          identifier: HarnessMonitorAccessibility.preferencesState,
          text: preferencesStateLabel
        )
      }
    }
  }
}
