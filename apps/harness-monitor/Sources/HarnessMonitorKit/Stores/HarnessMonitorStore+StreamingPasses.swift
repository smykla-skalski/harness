import Foundation

/// What a stream loop should do once a pass over its stream has ended.
enum StreamPassOutcome {
  case stop
  case retry(after: Duration)
}

extension HarnessMonitorStore {
  struct GlobalStreamPassState {
    var attempt = 0
    var hasSeenReady = false
  }

  func runGlobalStreamPass(
    using client: any HarnessMonitorClientProtocol,
    state: inout GlobalStreamPassState
  ) async -> StreamPassOutcome {
    do {
      for try await event in await client.globalStream() {
        recordReconnectRecovery(detail: "Global stream restored")
        state.attempt = 0
        recordStreamEvent(countedInTraffic: true)
        guard
          await processGlobalStreamEvent(
            event,
            using: client,
            hasSeenReady: &state.hasSeenReady
          )
        else {
          return .stop
        }
      }
    } catch {
      if Task.isCancelled {
        return .stop
      }
      recordReconnectAttempt(scope: "global stream", nextAttempt: state.attempt + 1, error: error)
      // The WebSocket receive loop already released its task (see
      // `releaseDeadWebSocketTask`), so every retry against this
      // transport will throw `connectionClosed` again until the manifest
      // watcher rebuilds the client. Skip the full 6-attempt backoff
      // and re-bootstrap directly — saves ~15 s and ~7 log lines per
      // daemon-flap cycle.
      if Self.isTransportClosedError(error) {
        appendConnectionEvent(
          kind: .reconnecting,
          detail: "Transport closed, re-bootstrapping global stream"
        )
        scheduleReconnectAfterConnectionFailure()
        return .stop
      }
    }

    return nextStreamPassOutcome(scope: "Global stream", attempt: &state.attempt)
  }

  func runSessionStreamPass(
    using client: any HarnessMonitorClientProtocol,
    sessionID: String,
    attempt: inout Int
  ) async -> StreamPassOutcome {
    do {
      for try await event in await client.sessionStream(sessionID: sessionID) {
        recordReconnectRecovery(detail: "Session stream restored")
        attempt = 0
        let countedInTraffic = activeTransport == .httpSSE
        recordStreamEvent(countedInTraffic: countedInTraffic)
        if case .ready = event.kind {
          await recoverSelectedSessionPushOnlyState(
            using: client,
            sessionID: sessionID
          )
          continue
        }
        await applySessionPushEventFromStream(event)
      }
    } catch {
      if Task.isCancelled {
        return .stop
      }
      recordReconnectAttempt(scope: "session stream", nextAttempt: attempt + 1, error: error)
      if Self.isTransportClosedError(error) {
        appendConnectionEvent(
          kind: .reconnecting,
          detail: "Transport closed, re-bootstrapping session stream"
        )
        scheduleReconnectAfterConnectionFailure()
        return .stop
      }
    }

    return nextStreamPassOutcome(scope: "Session stream", attempt: &attempt)
  }

  private func nextStreamPassOutcome(
    scope: String,
    attempt: inout Int
  ) -> StreamPassOutcome {
    if Task.isCancelled {
      return .stop
    }

    if attempt >= Self.streamReconnectMaxAttempts {
      appendConnectionEvent(
        kind: .reconnecting,
        detail: "\(scope) failed \(attempt) times, re-bootstrapping"
      )
      scheduleReconnectAfterConnectionFailure()
      return .stop
    }

    let delay = reconnectDelay(for: attempt)
    attempt += 1
    return .retry(after: delay)
  }
}
