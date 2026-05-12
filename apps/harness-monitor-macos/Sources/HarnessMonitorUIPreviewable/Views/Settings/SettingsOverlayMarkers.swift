import SwiftUI

public struct SettingsOverlayMarkers: View {
  public let themeMode: HarnessMonitorThemeMode
  public let selectedSection: SettingsSection
  @Environment(\.harnessTextSizeIndex)
  private var textSizeIndex
  @AppStorage(HarnessMonitorBackdropDefaults.modeKey)
  private var backdropModeRawValue = HarnessMonitorBackdropMode.none.rawValue
  @AppStorage(HarnessMonitorBackgroundDefaults.imageKey)
  private var backgroundImageRawValue = HarnessMonitorBackgroundSelection.defaultSelection
    .storageValue
  @AppStorage(HarnessMonitorSidebarSessionRowDisplayMode.storageKey)
  private var sidebarSessionRowDisplayModeRawValue =
    HarnessMonitorSidebarSessionRowDisplayMode.defaultMode.rawValue
  @AppStorage(SessionWindowKeyboardShortcutOverlaySettings.storageKey)
  private var sessionShortcutOverlaysEnabled =
    SessionWindowKeyboardShortcutOverlaySettings.defaultValue
  @AppStorage(HarnessMonitorSessionTitleBlurDefaults.enabledKey)
  private var sessionTitleBlurEnabled = HarnessMonitorSessionTitleBlurDefaults.enabledDefault
  @AppStorage(HarnessMonitorMenuBarDefaults.stateColorVariantsEnabledKey)
  private var menuBarStateColorVariantsEnabled =
    HarnessMonitorMenuBarDefaults.stateColorVariantsEnabledDefault
  @AppStorage(HarnessMonitorDateTimeConfiguration.timeZoneModeKey)
  private var timeZoneModeRawValue = HarnessMonitorDateTimeConfiguration.defaultTimeZoneModeRawValue
  @AppStorage(HarnessMonitorDateTimeConfiguration.customTimeZoneIdentifierKey)
  private var customTimeZoneIdentifier = HarnessMonitorDateTimeConfiguration
    .defaultCustomTimeZoneIdentifier

  public init(themeMode: HarnessMonitorThemeMode, selectedSection: SettingsSection) {
    self.themeMode = themeMode
    self.selectedSection = selectedSection
  }

  private var dateTimeConfiguration: HarnessMonitorDateTimeConfiguration {
    HarnessMonitorDateTimeConfiguration(
      timeZoneModeRawValue: timeZoneModeRawValue,
      customTimeZoneIdentifier: customTimeZoneIdentifier
    )
  }

  private var sidebarSessionRowDisplayMode: HarnessMonitorSidebarSessionRowDisplayMode {
    HarnessMonitorSidebarSessionRowDisplayMode.resolved(
      rawValue: sidebarSessionRowDisplayModeRawValue
    )
  }

  private var settingsStateLabel: String {
    let backgroundSelection = HarnessMonitorBackgroundSelection.decode(backgroundImageRawValue)
    return [
      "mode=\(themeMode.rawValue)",
      "section=\(selectedSection.rawValue)",
      "backdrop=\(backdropModeRawValue)",
      "background=\(backgroundSelection.settingsStateValue)",
      "textSize=\(HarnessMonitorTextSize.label(for: textSizeIndex))",
      "controlSize=" + "\(HarnessMonitorTextSize.controlSizeLabel(at: textSizeIndex))",
      "sidebarRowMode=\(sidebarSessionRowDisplayMode.rawValue)",
      "shortcutOverlays=\(boolLabel(sessionShortcutOverlaysEnabled))",
      "titleBlur=\(boolLabel(sessionTitleBlurEnabled))",
      "menuBarStateColors=\(boolLabel(menuBarStateColorVariantsEnabled))",
      "timeZoneMode=\(dateTimeConfiguration.timeZoneMode.rawValue)",
      "timeZone=\(dateTimeConfiguration.settingsStateValue)",
      "settingsChrome=native",
    ].joined(separator: ", ")
  }

  private func boolLabel(_ value: Bool) -> String {
    value ? "enabled" : "disabled"
  }

  public var body: some View {
    if HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled {
      ZStack {
        Color.clear
          .allowsHitTesting(false)
          .accessibilityElement()
          .accessibilityLabel(selectedSection.title)
          .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTitle)
        AccessibilityTextMarker(
          identifier: HarnessMonitorAccessibility.settingsState,
          text: settingsStateLabel
        )
      }
    }
  }
}
