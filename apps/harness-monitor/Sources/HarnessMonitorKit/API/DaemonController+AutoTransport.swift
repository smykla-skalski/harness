import Foundation
import Synchronization

extension DaemonController {
  enum AutoTransportBootstrapOutcome: Sendable {
    case upgraded(any HarnessMonitorClientProtocol)
    case unavailable
    case timedOut
  }

  /// Cancellation cannot unwind an in-flight `health()` RPC on its own: the RPC
  /// parks on a continuation that only `disconnect()` fails, so without the
  /// handler a cancelled probe sits until the 120s RPC timeout. Shutting the
  /// transport down from `onCancel` fails the pending request and lets the
  /// attempt return promptly.
  public static func defaultWebSocketBootstrap(
    _ connection: HarnessMonitorConnection
  ) async -> (any HarnessMonitorClientProtocol)? {
    let transport = WebSocketTransport(connection: connection)
    return await withTaskCancellationHandler {
      do {
        try Task.checkCancellation()
        try await transport.connect()
        try Task.checkCancellation()
        _ = try await transport.health()
        try Task.checkCancellation()
        return transport
      } catch {
        await transport.shutdown()
        return nil
      }
    } onCancel: {
      // Unstructured tasks do not inherit cancellation, so this still runs.
      Task { await transport.shutdown() }
    }
  }

  func bootstrapAutoTransport(
    connection: HarnessMonitorConnection
  ) async -> AutoTransportBootstrapOutcome {
    let gracePeriod = autoTransportWebSocketGracePeriod
    // Keep the WebSocket attempt unstructured so a timed-out race can return
    // within the grace period. `withTaskGroup` always join-waits remaining
    // children, which pinned startup to a hung connect/health probe.
    let attempt = Task { await webSocketBootstrapper(connection) }
    let outcome = await raceAutoTransportAttempt(attempt, gracePeriod: gracePeriod)
    switch outcome {
    case .upgraded, .unavailable:
      return outcome
    case .timedOut:
      attempt.cancel()
      // A connect that already resumed can still finish after cancel. Shut the
      // late client down without blocking startup on that finish.
      Task {
        if let webSocketClient = await attempt.value {
          await webSocketClient.shutdown()
        }
      }
      return .timedOut
    }
  }

  private func raceAutoTransportAttempt(
    _ attempt: Task<(any HarnessMonitorClientProtocol)?, Never>,
    gracePeriod: Duration
  ) async -> AutoTransportBootstrapOutcome {
    var graceTimer: Task<Void, Never>?
    let outcome: AutoTransportBootstrapOutcome = await withCheckedContinuation { continuation in
      let finish = OnceResume(continuation)
      Task {
        if let webSocketClient = await attempt.value {
          finish.resume(returning: .upgraded(webSocketClient))
        } else {
          finish.resume(returning: .unavailable)
        }
      }
      graceTimer = Task {
        try? await Task.sleep(for: gracePeriod)
        finish.resume(returning: .timedOut)
      }
    }
    graceTimer?.cancel()
    return outcome
  }
}

/// Resumes a checked continuation at most once across concurrent race branches.
private final class OnceResume<T: Sendable>: Sendable {
  private let continuation: Mutex<CheckedContinuation<T, Never>?>

  init(_ continuation: CheckedContinuation<T, Never>) {
    self.continuation = Mutex(continuation)
  }

  func resume(returning value: T) {
    let pending = continuation.withLock { stored in
      defer { stored = nil }
      return stored
    }
    pending?.resume(returning: value)
  }
}
