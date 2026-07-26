import Foundation

extension HarnessMonitorStore {
  func startConnectionProbe(using client: any HarnessMonitorClientProtocol) {
    stopConnectionProbe()
    guard maintainsLiveDaemonObservation else {
      return
    }
    connectionProbeTask = Task { @MainActor [weak self] in
      var consecutiveFailures = 0
      while !Task.isCancelled {
        // The store is taken for each tick and let go again before the wait.
        // This loop never ends on its own, so a reference held between ticks
        // would keep a store nobody owns any more probing a daemon nobody is
        // watching for the life of the process.
        let interval: Duration
        if let store = self {
          interval = store.connectionProbeInterval
        } else {
          return
        }
        try? await Task.sleep(for: interval)
        guard !Task.isCancelled else {
          return
        }
        if let store = self {
          guard
            await store.runConnectionProbePass(
              using: client,
              consecutiveFailures: &consecutiveFailures
            )
          else {
            return
          }
        } else {
          return
        }
      }
    }
  }

  /// One probe tick. Returns false when the loop should stop.
  private func runConnectionProbePass(
    using client: any HarnessMonitorClientProtocol,
    consecutiveFailures: inout Int
  ) async -> Bool {
    // Skip the probe while a reconnect cycle is in flight. The stream
    // reconnect loop already logged "reconnecting <scope> attempt N";
    // firing another RPC into the dead socket here just produces a
    // duplicate "Latency probe failed" line. The next successful
    // reconnect resets `reconnectAttempt` to zero and probing resumes.
    guard
      connectionState == .online,
      !isRefreshing,
      !isSessionActionInFlight,
      connectionMetrics.reconnectAttempt == 0
    else {
      return true
    }

    do {
      if let transportLatencyMs = try await client.transportLatencyMs() {
        consecutiveFailures = 0
        recordRequestSuccess(
          latencyMs: transportLatencyMs,
          latencySource: .transport,
          countsTowardsTraffic: false
        )
        await refreshLocalBridgeStateIfNeeded()
        return true
      }
      let sample = try await Self.measureOperation {
        try await client.health()
      }
      consecutiveFailures = 0
      recordRequestSuccess(
        latencyMs: sample.latencyMs,
        latencySource: .request,
        countsTowardsTraffic: false
      )
      await refreshLocalBridgeStateIfNeeded()
      return true
    } catch {
      if Task.isCancelled {
        return false
      }
      consecutiveFailures += 1
      appendConnectionEvent(
        kind: .error,
        detail: "Latency probe failed: \(error.localizedDescription)"
      )

      guard consecutiveFailures >= 2 else {
        return true
      }
      appendConnectionEvent(
        kind: .reconnecting,
        detail: "Probe failed \(consecutiveFailures) times, re-bootstrapping"
      )
      scheduleReconnectAfterConnectionFailure()
      return false
    }
  }

  func stopConnectionProbe() {
    connectionProbeTask?.cancel()
    connectionProbeTask = nil
  }

  private func refreshLocalBridgeStateIfNeeded() async {
    guard let manifestURL, !usesRemoteDaemon else {
      return
    }
    await refreshBridgeStateFromManifest(at: manifestURL)
  }
}
