import Foundation

extension HarnessMonitorStore {
  struct MeasuredOperation<Value: Sendable>: Sendable {
    let value: Value
    let latencyMs: Int
  }

  nonisolated static func measureOperation<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
  ) async throws -> MeasuredOperation<Value> {
    let startedAt = ContinuousClock.now
    let value = try await operation()
    let duration = startedAt.duration(to: ContinuousClock.now)
    return MeasuredOperation(
      value: value,
      latencyMs: max(0, Int(duration.components.seconds * 1_000))
        + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    )
  }
}

extension HarnessMonitorStore.ConnectionState {
  var isSupervisorDisconnectedState: Bool {
    switch self {
    case .connecting, .offline:
      true
    case .idle, .online:
      false
    }
  }
}
