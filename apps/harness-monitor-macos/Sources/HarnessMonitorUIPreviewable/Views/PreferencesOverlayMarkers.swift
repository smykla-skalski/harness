import SwiftUI

public struct PreferencesOverlayMarkers: View {
  public let themeMode: HarnessMonitorThemeMode
  public let selectedSection: PreferencesSection
  @Environment(\.harnessTextSizeIndex)
  private var textSizeIndex
  @AppStorage(HarnessMonitorBackdropDefaults.modeKey)
  private var backdropModeRawValue = HarnessMonitorBackdropMode.none.rawValue
  @AppStorage(HarnessMonitorBackgroundDefaults.imageKey)
  private var backgroundImageRawValue = HarnessMonitorBackgroundSelection.defaultSelection
    .storageValue
  @AppStorage(HarnessMonitorDateTimeConfiguration.timeZoneModeKey)
  private var timeZoneModeRawValue = HarnessMonitorDateTimeConfiguration.defaultTimeZoneModeRawValue
  @AppStorage(HarnessMonitorDateTimeConfiguration.customTimeZoneIdentifierKey)
  private var customTimeZoneIdentifier = HarnessMonitorDateTimeConfiguration
    .defaultCustomTimeZoneIdentifier

  public init(themeMode: HarnessMonitorThemeMode, selectedSection: PreferencesSection) {
    self.themeMode = themeMode
    self.selectedSection = selectedSection
  }

  private var dateTimeConfiguration: HarnessMonitorDateTimeConfiguration {
    HarnessMonitorDateTimeConfiguration(
      timeZoneModeRawValue: timeZoneModeRawValue,
      customTimeZoneIdentifier: customTimeZoneIdentifier
    )
  }

  private var preferencesStateLabel: String {
    let backgroundSelection = HarnessMonitorBackgroundSelection.decode(backgroundImageRawValue)
    return [
      "mode=\(themeMode.rawValue)",
      "section=\(selectedSection.rawValue)",
      "backdrop=\(backdropModeRawValue)",
      "background=\(backgroundSelection.preferencesStateValue)",
      "textSize=\(HarnessMonitorTextSize.label(for: textSizeIndex))",
      "controlSize=" + "\(HarnessMonitorTextSize.controlSizeLabel(at: textSizeIndex))",
      "timeZoneMode=\(dateTimeConfiguration.timeZoneMode.rawValue)",
      "timeZone=\(dateTimeConfiguration.preferencesStateValue)",
      "preferencesChrome=native",
    ].joined(separator: ", ")
  }

  public var body: some View {
    if HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled {
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
