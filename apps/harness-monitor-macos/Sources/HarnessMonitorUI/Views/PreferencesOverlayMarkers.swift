import SwiftUI

struct PreferencesOverlayMarkers: View {
  let themeMode: HarnessMonitorThemeMode
  let selectedSection: PreferencesSection
  @Environment(\.harnessTextSizeIndex)
  private var textSizeIndex
  @AppStorage(HarnessMonitorDateTimeConfiguration.timeZoneModeKey)
  private var timeZoneModeRawValue = HarnessMonitorDateTimeConfiguration.defaultTimeZoneModeRawValue
  @AppStorage(HarnessMonitorDateTimeConfiguration.customTimeZoneIdentifierKey)
  private var customTimeZoneIdentifier = HarnessMonitorDateTimeConfiguration.defaultCustomTimeZoneIdentifier

  private var dateTimeConfiguration: HarnessMonitorDateTimeConfiguration {
    HarnessMonitorDateTimeConfiguration(
      timeZoneModeRawValue: timeZoneModeRawValue,
      customTimeZoneIdentifier: customTimeZoneIdentifier
    )
  }

  private var preferencesStateLabel: String {
    [
      "mode=\(themeMode.rawValue)",
      "section=\(selectedSection.rawValue)",
      "textSize=\(HarnessMonitorTextSize.label(for: textSizeIndex))",
      "controlSize=" +
        "\(HarnessMonitorTextSize.controlSizeLabel(at: textSizeIndex))",
      "timeZoneMode=\(dateTimeConfiguration.timeZoneMode.rawValue)",
      "timeZone=\(dateTimeConfiguration.preferencesStateValue)",
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
