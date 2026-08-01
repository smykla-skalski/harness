import Foundation

extension WebSocketTransport {
  // MARK: - Streams

  /// Termination reason for the global and session stream continuations, in
  /// a local alias so the onTermination callbacks below stay readable.
  typealias StreamTermination = AsyncThrowingStream<DaemonPushEvent, Error>.Continuation.Termination

  public func globalStream() async -> DaemonPushEventStream {
    let (stream, continuation) = AsyncThrowingStream<DaemonPushEvent, Error>.makeStream()
    globalStreamContinuation = continuation
    globalSubscriptionActive = true

    continuation.onTermination = { [weak self] termination in
      guard let self else { return }
      Task { await self.cleanupGlobalSubscription(termination: termination) }
    }

    Task {
      do {
        _ = try await self.rpc(
          method: .streamSubscribe,
          params: .object(["scope": .string("global")])
        )
      } catch {
        continuation.finish(throwing: error)
      }
    }

    return stream
  }

  func cleanupGlobalSubscription(
    termination: StreamTermination
  ) {
    // Only the transport's `terminateAllStreams()` calls `continuation.finish()`
    // (which produces `.finished`) while `reconnectingStreams` is true. A
    // consumer-driven termination (Task cancellation, app lifecycle) reports
    // `.cancelled` here instead, and the desired-subscription flag must drop
    // so the in-flight receive loop's `resubscribe()` does not re-issue
    // `streamSubscribe` for a stream the consumer no longer wants.
    // `if case .finished` matches without relying on `Termination: Equatable`,
    // which the standard library type does not promise.
    globalStreamContinuation = nil
    if reconnectingStreams, case .finished = termination {
      HarnessMonitorLogger.websocket.debug(
        "skipping global unsubscribe: transport reconnect in progress"
      )
      return
    }
    globalSubscriptionActive = false
    Task {
      try? await rpc(
        method: .streamUnsubscribe,
        params: .object(["scope": .string("global")])
      )
    }
  }

  public func sessionStream(sessionID: String) async -> DaemonPushEventStream {
    let (stream, continuation) = AsyncThrowingStream<DaemonPushEvent, Error>.makeStream()
    sessionStreamContinuations[sessionID] = continuation
    activeSubscriptions.insert(sessionID)

    continuation.onTermination = { [weak self] termination in
      guard let self else { return }
      Task { await self.cleanupSessionSubscription(sessionID: sessionID, termination: termination) }
    }

    Task {
      do {
        _ = try await self.rpc(
          method: .sessionSubscribe,
          params: .object(["session_id": .string(sessionID)])
        )
      } catch {
        continuation.finish(throwing: error)
      }
    }

    return stream
  }

  func cleanupSessionSubscription(
    sessionID: String,
    termination: StreamTermination
  ) {
    // Mirror `cleanupGlobalSubscription`: a transport reconnect leaves the
    // desired-subscription set intact so `resubscribe()` re-issues
    // `session.subscribe` on the new socket, but a consumer cancellation
    // still drops the session from `activeSubscriptions` to stop the same
    // reconnect from re-subscribing to it.
    sessionStreamContinuations[sessionID] = nil
    if reconnectingStreams, case .finished = termination {
      HarnessMonitorLogger.websocket.debug(
        "skipping session unsubscribe for \(sessionID, privacy: .public): transport reconnect in progress"
      )
      return
    }
    activeSubscriptions.remove(sessionID)
    Task {
      try? await rpc(
        method: .sessionUnsubscribe,
        params: .object(["session_id": .string(sessionID)])
      )
    }
  }
}
