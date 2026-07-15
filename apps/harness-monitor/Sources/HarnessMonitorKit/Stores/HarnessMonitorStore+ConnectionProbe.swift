import Foundation

extension HarnessMonitorStore {
  func startConnectionProbe(using client: any HarnessMonitorClientProtocol) {
    stopConnectionProbe()
    guard maintainsLiveDaemonObservation else {
      return
    }
    connectionProbeTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }

      var consecutiveFailures = 0
      while !Task.isCancelled {
        try? await Task.sleep(for: connectionProbeInterval)
        guard !Task.isCancelled else {
          return
        }
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
          continue
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
            continue
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
        } catch {
          if Task.isCancelled {
            return
          }
          consecutiveFailures += 1
          appendConnectionEvent(
            kind: .error,
            detail: "Latency probe failed: \(error.localizedDescription)"
          )

          if consecutiveFailures >= 2 {
            appendConnectionEvent(
              kind: .reconnecting,
              detail: "Probe failed \(consecutiveFailures) times, re-bootstrapping"
            )
            scheduleReconnectAfterConnectionFailure()
            return
          }
        }
      }
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
