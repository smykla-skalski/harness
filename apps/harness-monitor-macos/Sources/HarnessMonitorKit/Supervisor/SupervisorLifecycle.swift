import Foundation

/// Bridges the Monitor supervisor tick loop to macOS lifecycle hooks
/// (`NSBackgroundActivityScheduler`, resign/become active, quit-on-close toggle). Phase 1
/// ships the symbol so the `HarnessMonitorStore+Supervisor` extension can call
/// `startBackgroundActivity` / `stopBackgroundActivity` without waiting for Phase 2 worker 6.
public final class SupervisorLifecycle: @unchecked Sendable {
  public init() {}

  /// Phase 1 no-op. Phase 2 worker 6 wires `NSBackgroundActivityScheduler` with
  /// identifier `io.harnessmonitor.supervisor`, QoS `.utility`, 30-second tolerance.
  public func startBackgroundActivity() {
    // Intentionally empty.
  }

  /// Phase 1 no-op. Phase 2 worker 6 invalidates the scheduler.
  public func stopBackgroundActivity() {
    // Intentionally empty.
  }
}
