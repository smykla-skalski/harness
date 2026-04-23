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

  /// Background activity identifier passed to `NSBackgroundActivityScheduler`.
  public static let activityIdentifier = "io.harnessmonitor.supervisor"

  /// Default tick interval in seconds.
  public static let defaultIntervalSeconds: TimeInterval = 10

  /// Preferred tolerance (± seconds) passed to `NSBackgroundActivityScheduler`.
  ///
  /// `SupervisorLifecycle` clamps this below the active interval because AppKit requires
  /// tolerance to stay strictly less than `interval`.
  public static let schedulerTolerance: TimeInterval = 30
}
