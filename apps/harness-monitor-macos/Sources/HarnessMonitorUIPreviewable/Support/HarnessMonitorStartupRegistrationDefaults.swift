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
    ]
    dict.merge(HarnessMonitorLoggerDefaults.registrationDefaults()) { _, new in new }
    #if HARNESS_FEATURE_LOTTIE
      dict[HarnessMonitorCornerAnimationDefaults.enabledKey] = false
    #endif
    dict.merge(HarnessMonitorVoicePreferences.registrationDefaults()) { _, new in new }
    dict.merge(HarnessMonitorMCPPreferencesDefaults.registrationDefaults()) { _, new in new }
    return dict
  }

  /// Registers all startup defaults on `userDefaults`. Pass `.standard` at app
  /// launch; pass a `UserDefaults(suiteName:)` instance in tests.
  public static func register(on userDefaults: UserDefaults) {
    userDefaults.register(defaults: values())
  }
}
