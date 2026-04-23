import Foundation

/// Preference keys and defaults for the supervisor background scheduler.
///
/// These keys are shared across `SupervisorLifecycle` (which reads them at scheduler start)
/// and the Preferences background pane (worker 23), which writes them via `@AppStorage`.
/// Both sides read from `UserDefaults.standard` so the lifecycle class does not need to
/// import SwiftUI.
public enum SupervisorPreferencesDefaults {
  /// `@AppStorage` key for "Run supervisor in background when no window is open".
  ///
  /// Type: `Bool`. Default: `true` — the scheduler starts unless the user opts out.
  public static let runInBackgroundKey = "supervisorRunInBackground"

  /// Default value for the background-activity toggle.
  public static let runInBackgroundDefault = true

  /// `@AppStorage` key for quiet-hours suppression.
  ///
  /// Type: `Bool`. Default: `false` — automatic actions keep running unless the
  /// user explicitly enables quiet hours.
  public static let quietHoursEnabledKey = "supervisorQuietHoursEnabled"

  /// Default value for the quiet-hours master toggle.
  public static let quietHoursEnabledDefault = false

  /// `@AppStorage` key for quiet-hours start time stored as minutes from midnight.
  public static let quietHoursStartMinutesKey = "supervisorQuietHoursStartMinutes"

  /// `@AppStorage` key for quiet-hours end time stored as minutes from midnight.
  public static let quietHoursEndMinutesKey = "supervisorQuietHoursEndMinutes"

  /// Default quiet-hours start time: 22:00 local time.
  public static let quietHoursStartMinutesDefault = 22 * 60

  /// Default quiet-hours end time: 07:00 local time.
  public static let quietHoursEndMinutesDefault = 7 * 60

  public static func quietHoursWindow(
    from userDefaults: UserDefaults = .standard
  ) -> SupervisorQuietHoursWindow? {
    let enabled = userDefaults.object(forKey: quietHoursEnabledKey) as? Bool
    guard enabled ?? quietHoursEnabledDefault else {
      return nil
    }
    return SupervisorQuietHoursWindow(
      startMinutes: storedQuietHoursMinutes(
        from: userDefaults,
        key: quietHoursStartMinutesKey,
        defaultValue: quietHoursStartMinutesDefault
      ),
      endMinutes: storedQuietHoursMinutes(
        from: userDefaults,
        key: quietHoursEndMinutesKey,
        defaultValue: quietHoursEndMinutesDefault
      )
    )
  }

  /// Background activity identifier passed to `NSBackgroundActivityScheduler`.
  public static let activityIdentifier = "io.harnessmonitor.supervisor"

  /// Default tick interval in seconds.
  public static let defaultIntervalSeconds: TimeInterval = 10

  /// Preferred tolerance (± seconds) passed to `NSBackgroundActivityScheduler`.
  ///
  /// `SupervisorLifecycle` clamps this below the active interval because AppKit requires
  /// tolerance to stay strictly less than `interval`.
  public static let schedulerTolerance: TimeInterval = 30

  private static func storedQuietHoursMinutes(
    from userDefaults: UserDefaults,
    key: String,
    defaultValue: Int
  ) -> Int {
    guard userDefaults.object(forKey: key) != nil else {
      return defaultValue
    }
    return userDefaults.integer(forKey: key)
  }
}
