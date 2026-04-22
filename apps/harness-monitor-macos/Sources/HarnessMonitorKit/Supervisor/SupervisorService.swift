import Foundation

/// Actor owning the Monitor supervisor tick loop. Phase 1 ships the public surface so store /
/// lifecycle / preferences code can reference `SupervisorService` without waiting for Phase 2
/// worker 5 to fill the `TaskGroup` fan-out, quarantine counting, and observer routing.
public actor SupervisorService {
  private let registry: PolicyRegistry
  private let executor: PolicyExecutor
  private let interval: TimeInterval
  private var running = false
  private var autoActionsSuppressed = false

  public init(
    store: HarnessMonitorStore?,
    registry: PolicyRegistry,
    executor: PolicyExecutor,
    clock: Any?,
    interval: TimeInterval
  ) {
    // Phase 1 no-op: `store` and `clock` parameters match the source-plan test signature so
    // Phase 2 worker 5 can swap the body in without touching call sites.
    _ = store
    _ = clock
    self.registry = registry
    self.executor = executor
    self.interval = interval
  }

  public func start() async {
    running = true
  }

  public func stop() async {
    running = false
  }

  /// Runs a single tick. Phase 1 no-op; Phase 2 worker 5 wires snapshot → registry → executor.
  public func runOneTick() async {
    // Intentionally empty. The signature is frozen.
    _ = registry
    _ = executor
  }

  /// Suppress automatic actions for the duration of the supplied operation. Phase 2 worker 5
  /// implements the real suppression semantics; Phase 1 just forwards to the closure.
  public func suppressAutoActions<Result>(
    during operation: () async throws -> Result
  ) async rethrows -> Result {
    autoActionsSuppressed = true
    defer { autoActionsSuppressed = false }
    return try await operation()
  }
}
