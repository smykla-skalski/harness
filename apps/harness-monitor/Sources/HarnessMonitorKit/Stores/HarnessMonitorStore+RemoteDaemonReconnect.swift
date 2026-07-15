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
      guard let self else { return }
      await self.runRemoteDaemonReconnectLoop(generation: generation)
    }
  }

  func stopRemoteDaemonReconnect() {
    stopConnectionRecovery()
    remoteDaemonReconnectGeneration &+= 1
    remoteDaemonReconnectTask?.cancel()
    remoteDaemonReconnectTask = nil
  }

  private func runRemoteDaemonReconnectLoop(generation: UInt64) async {
    defer { finishRemoteDaemonReconnect(generation: generation) }
    var attempt = 0

    while shouldContinueRemoteDaemonReconnect(generation: generation) {
      let delay = reconnectDelay(for: attempt)
      appendConnectionEvent(
        kind: .reconnecting,
        detail: "Remote daemon unavailable; retrying after \(delay) (attempt \(attempt + 1))"
      )
      do {
        try await connection.remoteDaemonReconnectSleeper.sleep(for: delay)
      } catch {
        return
      }
      guard shouldContinueRemoteDaemonReconnect(generation: generation) else {
        return
      }

      await reconnect()
      guard connectionState != .online else {
        return
      }
      attempt += 1
    }
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
