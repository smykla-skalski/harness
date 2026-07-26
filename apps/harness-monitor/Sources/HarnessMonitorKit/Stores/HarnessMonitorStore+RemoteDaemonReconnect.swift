import Foundation

protocol RemoteDaemonReconnectSleeping: Sendable {
  func sleep(for delay: Duration) async throws
}

struct LiveRemoteDaemonReconnectSleeper: RemoteDaemonReconnectSleeping {
  func sleep(for delay: Duration) async throws {
    try await Task.sleep(for: delay)
  }
}

extension HarnessMonitorStore {
  var remoteDaemonReconnectTask: Task<Void, Never>? {
    get { connection.remoteDaemonReconnectTask }
    set { connection.remoteDaemonReconnectTask = newValue }
  }

  var remoteDaemonReconnectGeneration: UInt64 {
    get { connection.remoteDaemonReconnectGeneration }
    set { connection.remoteDaemonReconnectGeneration = newValue }
  }

  func scheduleRemoteDaemonReconnect(after error: (any Error)? = nil) {
    guard shouldRetryRemoteDaemonConnection(after: error) else {
      stopRemoteDaemonReconnect()
      return
    }
    guard remoteDaemonReconnectTask == nil else {
      return
    }

    remoteDaemonReconnectGeneration &+= 1
    let generation = remoteDaemonReconnectGeneration
    remoteDaemonReconnectTask = Task { @MainActor [weak self] in
      var attempt = 0
      while true {
        // The store is taken for each step and let go again before the wait.
        // This loop only ends once the store says so, so a reference held
        // across the backoff would keep a store nobody owns any more retrying
        // for the life of the process.
        let step: RemoteDaemonReconnectStep
        if let store = self {
          step = store.nextRemoteDaemonReconnectStep(generation: generation, attempt: attempt)
        } else {
          return
        }
        guard case .wait(let delay, let sleeper) = step else {
          return
        }
        do {
          try await sleeper.sleep(for: delay)
        } catch {
          self?.finishRemoteDaemonReconnect(generation: generation)
          return
        }
        if let store = self {
          guard await store.retryRemoteDaemonConnection(generation: generation) else {
            return
          }
        } else {
          return
        }
        attempt += 1
      }
    }
  }

  enum RemoteDaemonReconnectStep {
    case stop
    case wait(Duration, any RemoteDaemonReconnectSleeping)
  }

  func stopRemoteDaemonReconnect() {
    stopConnectionRecovery()
    remoteDaemonReconnectGeneration &+= 1
    remoteDaemonReconnectTask?.cancel()
    remoteDaemonReconnectTask = nil
  }

  private func nextRemoteDaemonReconnectStep(
    generation: UInt64,
    attempt: Int
  ) -> RemoteDaemonReconnectStep {
    guard shouldContinueRemoteDaemonReconnect(generation: generation) else {
      finishRemoteDaemonReconnect(generation: generation)
      return .stop
    }
    let delay = reconnectDelay(for: attempt)
    appendConnectionEvent(
      kind: .reconnecting,
      detail: "Remote daemon unavailable; retrying after \(delay) (attempt \(attempt + 1))"
    )
    return .wait(delay, connection.remoteDaemonReconnectSleeper)
  }

  /// One reconnect attempt. Returns false when the loop should stop.
  private func retryRemoteDaemonConnection(generation: UInt64) async -> Bool {
    guard shouldContinueRemoteDaemonReconnect(generation: generation) else {
      finishRemoteDaemonReconnect(generation: generation)
      return false
    }

    await reconnect()
    guard connectionState != .online else {
      finishRemoteDaemonReconnect(generation: generation)
      return false
    }
    return true
  }

  private func shouldContinueRemoteDaemonReconnect(generation: UInt64) -> Bool {
    !Task.isCancelled
      && generation == remoteDaemonReconnectGeneration
      && maintainsLiveDaemonObservation
      && !isAppLifecycleSuspended
      && !connection.isPreparingForTermination
      && remoteDaemonProfile?.status == .active
      && connectionState != .online
  }

  private func shouldRetryRemoteDaemonConnection(after error: (any Error)?) -> Bool {
    guard
      !Task.isCancelled,
      maintainsLiveDaemonObservation,
      !isAppLifecycleSuspended,
      !connection.isPreparingForTermination,
      remoteDaemonProfile?.status == .active,
      connectionState != .online
    else {
      return false
    }
    guard let error else {
      return true
    }
    // A disconnected URLSession/WebSocket can surface URLError.cancelled even
    // though the store's observation lifecycle is still active. The task and
    // lifecycle guards above distinguish that transport error from an
    // intentional cancellation.
    if error is CancellationError || error is RemoteDaemonProfileError {
      return false
    }
    if let apiError = error as? HarnessMonitorAPIError,
      case .server(let code, _) = apiError
    {
      return code == 408 || code == 429 || !(400..<500).contains(code)
    }
    return true
  }

  private func finishRemoteDaemonReconnect(generation: UInt64) {
    guard generation == remoteDaemonReconnectGeneration else {
      return
    }
    remoteDaemonReconnectTask = nil
  }
}
