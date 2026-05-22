import Foundation

/// Preference keys and defaults for the supervisor background scheduler.
///
/// These keys are shared across `SupervisorLifecycle` (which reads them at scheduler start)
/// and the Settings background pane (worker 23), which writes them via `@AppStorage`.
/// Both sides read from `UserDefaults.standard` so the lifecycle class does not need to
/// import SwiftUI.
public enum SupervisorSettingsDefaults {
  /// `@AppStorage` key for "Run supervisor in background when no window is open".
  ///
  /// Type: `Bool`. Default: `false` — users opt in before the app stays alive after close.
  public static let runInBackgroundKey = "supervisorRunInBackground"

  /// Default value for the background-activity toggle.
  public static let runInBackgroundDefault = false

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

  /// `@AppStorage` key for the audit retention window stored in seconds.
  ///
  /// Type: `TimeInterval` (`Double`). Default: `defaultAuditRetentionSeconds` (14 days).
  /// `SupervisorAuditRetention` reads this when computing the compaction cutoff and
  /// clamps the value to `[minAuditRetentionSeconds, maxAuditRetentionSeconds]`.
  public static let auditRetentionSecondsKey = "supervisor.audit.retentionSeconds"

  /// Default audit retention window: 14 days.
  public static let defaultAuditRetentionSeconds: TimeInterval = 14 * 24 * 60 * 60

  /// Minimum retention window: 1 day.
  public static let minAuditRetentionSeconds: TimeInterval = 24 * 60 * 60

  /// Maximum retention window: 90 days.
  public static let maxAuditRetentionSeconds: TimeInterval = 90 * 24 * 60 * 60

  /// Background activity identifier passed to `NSBackgroundActivityScheduler`.
  public static let activityIdentifier = "io.harnessmonitor.supervisor"

  /// Default tick interval in seconds.
  public static let defaultIntervalSeconds: TimeInterval = 10

  /// Preferred tolerance (± seconds) passed to `NSBackgroundActivityScheduler`.
  ///
  /// `SupervisorLifecycle` clamps this below the active interval because AppKit requires
  /// tolerance to stay strictly less than `interval`.
  public static let schedulerTolerance: TimeInterval = 30

  /// Resolves the configured audit retention window from `userDefaults`.
  ///
  /// Reads `auditRetentionSecondsKey`, clamps to `[minAuditRetentionSeconds, maxAuditRetentionSeconds]`,
  /// and falls back to `defaultAuditRetentionSeconds` when the key is missing or stored as a value
  /// that does not bridge to a finite `TimeInterval` (e.g. a non-numeric string).
  public static func auditRetentionSeconds(
    from userDefaults: UserDefaults = .standard
  ) -> TimeInterval {
    let stored = userDefaults.object(forKey: auditRetentionSecondsKey)
    let resolved: TimeInterval
    if let numeric = stored as? NSNumber {
      resolved = numeric.doubleValue
    } else if let numeric = stored as? TimeInterval {
      resolved = numeric
    } else {
      return defaultAuditRetentionSeconds
    }
    guard resolved.isFinite else {
      return defaultAuditRetentionSeconds
    }
    return min(maxAuditRetentionSeconds, max(minAuditRetentionSeconds, resolved))
  }

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
