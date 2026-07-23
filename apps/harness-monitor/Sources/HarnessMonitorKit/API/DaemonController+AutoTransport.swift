import Foundation
import Synchronization

extension DaemonController {
  enum AutoTransportBootstrapOutcome: Sendable {
    case upgraded(any HarnessMonitorClientProtocol)
    case unavailable
    case timedOut
    case cancelled
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

  /// Releases `client` and reports cancellation, so a caller that gave up
  /// during the race never receives a live client it does not know to close.
  /// A bare `checkCancellation` here would leak the socket it hands back.
  func requireNotCancelled(releasing client: any HarnessMonitorClientProtocol) async throws {
    guard Task.isCancelled else {
      return
    }
    await client.shutdown()
    throw CancellationError()
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
    case .timedOut, .cancelled:
      attempt.cancel()
      // A connect that already resumed can still finish after cancel. Shut the
      // late client down without blocking startup on that finish.
      Task {
        if let webSocketClient = await attempt.value {
          await webSocketClient.shutdown()
        }
      }
      return outcome
    }
  }

  /// `attempt` is unstructured, and awaiting a non-throwing task's value is not
  /// cancellable, so the race has to observe the caller's cancellation itself.
  /// Without the handler a cancelled bootstrap still waits out the grace period.
  private func raceAutoTransportAttempt(
    _ attempt: Task<(any HarnessMonitorClientProtocol)?, Never>,
    gracePeriod: Duration
  ) async -> AutoTransportBootstrapOutcome {
    let race = AutoTransportRace()
    var graceTimer: Task<Void, Never>?
    let outcome = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard race.install(continuation) else {
          return
        }
        Task {
          if let webSocketClient = await attempt.value {
            race.finish(.upgraded(webSocketClient))
          } else {
            race.finish(.unavailable)
          }
        }
        graceTimer = Task {
          do {
            try await Task.sleep(for: gracePeriod)
          } catch {
            return
          }
          race.finish(.timedOut)
        }
      }
    } onCancel: {
      race.finish(.cancelled)
    }
    graceTimer?.cancel()
    return outcome
  }
}

/// Delivers the first of the race's branches to the awaiting continuation and
/// drops the rest. `onCancel` can fire before the continuation exists, so a
/// finish that arrives early is held until `install` can hand it over.
private final class AutoTransportRace: Sendable {
  fileprivate typealias Outcome = DaemonController.AutoTransportBootstrapOutcome

  private enum State {
    case idle
    case waiting(CheckedContinuation<Outcome, Never>)
    case finishedEarly(Outcome)
    case delivered
  }

  private let state = Mutex<State>(.idle)

  /// Returns false when the race already finished, meaning the caller must not
  /// start the branches because the continuation is spoken for.
  func install(_ continuation: CheckedContinuation<Outcome, Never>) -> Bool {
    let early: Outcome? = state.withLock { current in
      switch current {
      case .idle:
        current = .waiting(continuation)
        return nil
      case .finishedEarly(let outcome):
        current = .delivered
        return outcome
      case .waiting, .delivered:
        return nil
      }
    }
    guard let early else {
      return true
    }
    continuation.resume(returning: early)
    return false
  }

  func finish(_ outcome: Outcome) {
    let pending: CheckedContinuation<Outcome, Never>? = state.withLock { current in
      switch current {
      case .idle:
        current = .finishedEarly(outcome)
        return nil
      case .waiting(let continuation):
        current = .delivered
        return continuation
      case .finishedEarly, .delivered:
        return nil
      }
    }
    pending?.resume(returning: outcome)
  }
}
