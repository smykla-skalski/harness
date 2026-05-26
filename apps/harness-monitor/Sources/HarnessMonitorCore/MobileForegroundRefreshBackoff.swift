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
