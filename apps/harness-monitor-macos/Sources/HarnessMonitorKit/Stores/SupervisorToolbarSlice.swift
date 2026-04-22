import Foundation
import Observation

/// Observable slice consumed by the toolbar bell. Phase 1 ships the stub — Phase 2 worker 18
/// subscribes `start(decisions:)` to `DecisionStore.events` and keeps `count` / `maxSeverity`
/// live.
@MainActor
@Observable
public final class SupervisorToolbarSlice {
  public private(set) var count: Int = 0
  public private(set) var maxSeverity: DecisionSeverity?

  public init() {}

  /// Phase 1 no-op. Phase 2 worker 18 wires the AsyncStream subscription.
  public func start(decisions: DecisionStore) {
    _ = decisions
  }

  public func stop() {
    // Phase 1 no-op.
  }
}
