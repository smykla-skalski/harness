import Foundation
import HarnessMonitorKit

/// The single source of truth for every `UserDefaults.register(defaults:)` entry
/// that Harness Monitor establishes at application startup.
public enum HarnessMonitorStartupRegistrationDefaults {
  /// Builds and returns the complete registration-defaults dictionary that the
  /// app passes to `UserDefaults.register(defaults:)` on every launch.
  public static func values() -> [String: Any] {
    var dict: [String: Any] = [
      HarnessMonitorBackdropDefaults.modeKey: HarnessMonitorBackdropMode.none.rawValue,
      HarnessMonitorBackgroundDefaults.imageKey:
        HarnessMonitorBackgroundSelection.defaultSelection.storageValue,
      HarnessMonitorTextSize.storageKey: HarnessMonitorTextSize.defaultIndex,
      HarnessMonitorDateTimeConfiguration.timeZoneModeKey:
        HarnessMonitorDateTimeConfiguration.defaultTimeZoneModeRawValue,
      HarnessMonitorDateTimeConfiguration.customTimeZoneIdentifierKey:
        HarnessMonitorDateTimeConfiguration.defaultCustomTimeZoneIdentifier,
      HarnessMonitorAgentTuiDefaults.submitSendsEnterKey:
        HarnessMonitorAgentTuiDefaults.submitSendsEnterDefault,
      HarnessMonitorLaunchBehavior.storageKey: HarnessMonitorLaunchBehavior.defaultValue.rawValue,
      OpenRecentCloseAfterPickDefaults.storageKey: OpenRecentCloseAfterPickDefaults.defaultValue,
    ]
    dict.merge(SessionPendingDecisionBannerSettings.registrationDefaults()) { _, new in new }
    dict.merge(HarnessMonitorLoggerDefaults.registrationDefaults()) { _, new in new }
    dict.merge(HarnessMonitorMenuBarDefaults.registrationDefaults()) { _, new in new }
    dict.merge(HarnessMonitorSessionTitleBlurDefaults.registrationDefaults()) { _, new in new }
    dict.merge(HarnessMonitorVoiceSettings.registrationDefaults()) { _, new in new }
    dict.merge(HarnessMonitorMCPSettingsDefaults.registrationDefaults()) { _, new in new }
    dict.merge(HarnessMonitorToolCallAnnouncementSettings.registrationDefaults()) { _, new in
      new
    }
    return dict
  }

  /// Registers all startup defaults on `userDefaults`. Pass `.standard` at app
  /// launch; pass a `UserDefaults(suiteName:)` instance in tests.
  public static func register(on userDefaults: UserDefaults) {
    userDefaults.register(defaults: values())
  }
}
