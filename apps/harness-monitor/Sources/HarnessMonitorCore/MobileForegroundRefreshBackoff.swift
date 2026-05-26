import Foundation

/// Spacing between foreground mirror refreshes. Holds a steady base cadence while syncs
/// succeed and backs off geometrically while they keep failing, so a device that is offline
/// or signed out of iCloud stops hammering CloudKit on a flat timer.
public struct MobileForegroundRefreshBackoff: Sendable, Equatable {
  public let baseInterval: Duration
  public let maximumInterval: Duration
  public private(set) var currentInterval: Duration

  public init(
    baseInterval: Duration = .seconds(15),
    maximumInterval: Duration = .seconds(120)
  ) {
    let normalizedMaximum = maximumInterval < baseInterval ? baseInterval : maximumInterval
    self.baseInterval = baseInterval
    self.maximumInterval = normalizedMaximum
    self.currentInterval = baseInterval
  }

  public mutating func recordSuccess() {
    currentInterval = baseInterval
  }

  public mutating func recordFailure() {
    let doubled = currentInterval * 2
    currentInterval = doubled > maximumInterval ? maximumInterval : doubled
  }
}

/// Rate gate that allows an action at most once per `minimumInterval`, so a watch that keeps
/// settling to a stale "no mirror" state can re-request fresh pairing material from the iPhone
/// without firing on every foreground refresh. Paired with `MobileWatchPairingTransfer`'s change
/// gate (which dedups an unchanged response), this recovers a stale credential without churn.
public struct MobilePairingRefreshThrottle: Sendable, Equatable {
  public let minimumInterval: TimeInterval
  public private(set) var lastRequestedAt: Date?

  public init(minimumInterval: TimeInterval = 60) {
    self.minimumInterval = max(0, minimumInterval)
    self.lastRequestedAt = nil
  }

  /// Returns true and records `now` when at least `minimumInterval` has elapsed since the last
  /// allowed request (or none has happened yet); returns false otherwise.
  public mutating func shouldRequest(now: Date) -> Bool {
    if let lastRequestedAt, now.timeIntervalSince(lastRequestedAt) < minimumInterval {
      return false
    }
    lastRequestedAt = now
    return true
  }
}
