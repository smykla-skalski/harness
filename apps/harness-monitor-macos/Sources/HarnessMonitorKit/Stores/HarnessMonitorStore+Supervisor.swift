import Foundation

extension HarnessMonitorStore {
  /// Shared toolbar slice consumed by `ContentToolbarItems`. Phase 1 returns a fresh instance
  /// every call because nothing mutates it yet; Phase 2 worker 18 replaces this with a cached
  /// slice wired to the active `DecisionStore`.
  public var supervisorToolbarSlice: SupervisorToolbarSlice {
    SupervisorToolbarSlice()
  }

  /// Phase 1 no-op. Phase 2 worker 6 boots the `SupervisorService` tick loop plus the
  /// `NSBackgroundActivityScheduler`.
  public func startSupervisor() {
    // Intentionally empty — the live surface is wired in Phase 2.
  }

  /// Phase 1 no-op. Phase 2 worker 6 tears down the scheduler and drains the current tick.
  public func stopSupervisor() {
    // Intentionally empty.
  }
}
