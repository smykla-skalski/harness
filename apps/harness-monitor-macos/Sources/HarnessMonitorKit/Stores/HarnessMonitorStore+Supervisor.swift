import Foundation

extension HarnessMonitorStore {
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
