import Foundation

/// Bridges the supervisor process lifetime to macOS background-activity scheduling.
///
/// `SupervisorService` owns the policy tick loop. `startBackgroundActivity` only arms an
/// `NSBackgroundActivityScheduler` so macOS knows Monitor has lightweight background work when
/// the "Run in background" preference is enabled.
///
/// `onTick` remains an optional test hook for this wrapper. Production startup does not wire it
/// to `SupervisorService`, which keeps policy ticks single-owned by the service loop.
public final class SupervisorLifecycle: @unchecked Sendable {
  // MARK: - State

  /// Whether an `NSBackgroundActivityScheduler` is currently armed.
  ///
  /// Exposed for tests; production code should call `startBackgroundActivity` /
  /// `stopBackgroundActivity` and let this property reflect the result.
  public private(set) var isBackgroundActivityScheduled: Bool = false

  /// Optional callback for tests and diagnostics. Production supervisor startup leaves this unset
  /// so background scheduling cannot create a second policy tick source.
  public var onTick: (@Sendable () async -> Void)?

  private var scheduler: NSBackgroundActivityScheduler?
  private let interval: TimeInterval
  private let tolerance: TimeInterval
  private let identifier: String

  // MARK: - Init

  public init(
    interval: TimeInterval = SupervisorSettingsDefaults.defaultIntervalSeconds,
    tolerance: TimeInterval = SupervisorSettingsDefaults.schedulerTolerance,
    identifier: String = SupervisorSettingsDefaults.activityIdentifier
  ) {
    self.interval = interval
    self.tolerance = tolerance
    self.identifier = identifier
  }

  // MARK: - Public API

  /// Arms the `NSBackgroundActivityScheduler` if the "Run in background" preference is
  /// enabled. Safe to call multiple times — a running scheduler is invalidated first.
  public func startBackgroundActivity() {
    stopBackgroundActivity()

    let enabled = UserDefaults.standard.object(
      forKey: SupervisorSettingsDefaults.runInBackgroundKey
    )
    let runInBackground: Bool
    if let storedValue = enabled as? Bool {
      runInBackground = storedValue
    } else {
      runInBackground = SupervisorSettingsDefaults.runInBackgroundDefault
    }

    guard runInBackground else {
      HarnessMonitorLogger.supervisorTrace(
        "supervisor.lifecycle.background_skipped reason=preference_disabled"
      )
      return
    }

    let activity = NSBackgroundActivityScheduler(identifier: identifier)
    activity.repeats = true
    activity.interval = interval
    activity.tolerance = normalizedTolerance
    activity.qualityOfService = .utility

    activity.schedule { [weak self] completion in
      guard let self else {
        completion(.deferred)
        return
      }
      HarnessMonitorLogger.supervisorDebug("supervisor.lifecycle.background_tick fired")
      Task {
        await self.onTick?()
        completion(.finished)
      }
    }

    scheduler = activity
    isBackgroundActivityScheduled = true
    let intervalValue = self.interval
    HarnessMonitorLogger.supervisorTrace(
      "supervisor.lifecycle.background_started interval=\(intervalValue)"
    )
  }

  /// Stops and invalidates the background activity scheduler. Idempotent.
  public func stopBackgroundActivity() {
    guard let activity = scheduler else {
      isBackgroundActivityScheduled = false
      return
    }
    activity.invalidate()
    scheduler = nil
    isBackgroundActivityScheduled = false
    HarnessMonitorLogger.supervisorTrace("supervisor.lifecycle.background_stopped")
  }

  // MARK: - Test hook

  /// Immediately invokes `onTick` inline, bypassing the scheduler. Only for tests.
  public func forceTick() async {
    await onTick?()
  }

  private var normalizedTolerance: TimeInterval {
    guard interval.isFinite, interval > 0 else {
      return 0
    }
    let requestedTolerance = max(0, tolerance)
    let maxAllowedTolerance = interval > 1 ? interval - 1 : interval / 2
    return min(requestedTolerance, maxAllowedTolerance)
  }
}
