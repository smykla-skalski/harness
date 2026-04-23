import Foundation

/// Value type consumed by `DecisionsLiveTickView`. Phase 2 worker 5 / 18 produces live values;
/// Phase 1 callers use `.placeholder` for preview-only rendering.
public struct DecisionLiveTickSnapshot: Sendable, Hashable {
  public let lastSnapshotID: String?
  public let tickLatencyP50Ms: Double
  public let tickLatencyP95Ms: Double
  public let activeObserverCount: Int
  public let quarantinedRuleIDs: [String]

  public init(
    lastSnapshotID: String?,
    tickLatencyP50Ms: Double,
    tickLatencyP95Ms: Double,
    activeObserverCount: Int,
    quarantinedRuleIDs: [String]
  ) {
    self.lastSnapshotID = lastSnapshotID
    self.tickLatencyP50Ms = tickLatencyP50Ms
    self.tickLatencyP95Ms = tickLatencyP95Ms
    self.activeObserverCount = activeObserverCount
    self.quarantinedRuleIDs = quarantinedRuleIDs
  }

  public static let placeholder = Self(
    lastSnapshotID: nil,
    tickLatencyP50Ms: 0,
    tickLatencyP95Ms: 0,
    activeObserverCount: 0,
    quarantinedRuleIDs: []
  )
}
