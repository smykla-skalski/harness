import Foundation

extension HarnessStore {
  private static let maxLatencySamples = 12
  private static let trafficWindow: TimeInterval = 30

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

  func resetConnectionMetrics(for transport: TransportKind) {
    activeTransport = transport
    connectionMetrics = .initial
    connectionMetrics.transportKind = transport
    connectionMetrics.connectedSince = .now
    connectionMetrics.isFallback = transport == .httpSSE
    latencySamplesMs.removeAll(keepingCapacity: true)
    trafficSampleTimes.removeAll(keepingCapacity: true)
  }

  func markConnectionOffline(_ message: String) {
    connectionState = .offline(message)
    lastError = message
    stopConnectionProbe()
    connectionMetrics.connectedSince = nil
    connectionMetrics.latencyMs = nil
    connectionMetrics.lastMessageAt = nil
    connectionMetrics.messagesPerSecond = 0
    connectionMetrics.reconnectAttempt = 0
  }

  func recordRequestSuccess(
    latencyMs: Int? = nil,
    updatesLatency: Bool = false,
    countsTowardsTraffic: Bool = true,
    recordedAt: Date = .now
  ) {
    if updatesLatency, let latencyMs {
      updateLatency(latencyMs)
    }
    guard countsTowardsTraffic else {
      return
    }
    connectionMetrics.messagesSent += 1
    connectionMetrics.messagesReceived += 1
    connectionMetrics.lastMessageAt = recordedAt
    appendTrafficSamples(count: 2, at: recordedAt)
  }

  func recordStreamEvent(
    countedInTraffic: Bool,
    recordedAt: Date = .now
  ) {
    connectionMetrics.lastMessageAt = recordedAt
    guard countedInTraffic else {
      return
    }
    connectionMetrics.messagesReceived += 1
    appendTrafficSamples(count: 1, at: recordedAt)
  }

  func recordReconnectAttempt(scope: String, nextAttempt: Int, error: any Error) {
    if connectionMetrics.reconnectAttempt == 0 {
      connectionMetrics.reconnectCount += 1
    }
    connectionMetrics.reconnectAttempt = max(connectionMetrics.reconnectAttempt, nextAttempt)
    lastError = error.localizedDescription
    appendConnectionEvent(
      kind: .reconnecting,
      detail: "Reconnecting \(scope) (attempt \(nextAttempt))"
    )
  }

  func recordReconnectRecovery(detail: String) {
    guard connectionMetrics.reconnectAttempt > 0 else {
      return
    }
    connectionMetrics.reconnectAttempt = 0
    appendConnectionEvent(kind: .connected, detail: detail)
  }

  func startConnectionProbe(using client: any HarnessClientProtocol) {
    stopConnectionProbe()
    connectionProbeTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }

      while !Task.isCancelled {
        try? await Task.sleep(for: connectionProbeInterval)
        guard !Task.isCancelled else {
          return
        }
        guard connectionState == .online, !isRefreshing, !isSessionActionInFlight else {
          continue
        }

        do {
          let sample = try await Self.measureOperation {
            try await client.health()
          }
          recordRequestSuccess(
            latencyMs: sample.latencyMs,
            updatesLatency: true,
            countsTowardsTraffic: false
          )
        } catch {
          if Task.isCancelled {
            return
          }
          appendConnectionEvent(
            kind: .error,
            detail: "Latency probe failed: \(error.localizedDescription)"
          )
        }
      }
    }
  }

  func stopConnectionProbe() {
    connectionProbeTask?.cancel()
    connectionProbeTask = nil
  }

  private func updateLatency(_ latencyMs: Int) {
    connectionMetrics.latencyMs = latencyMs
    latencySamplesMs.append(latencyMs)
    if latencySamplesMs.count > Self.maxLatencySamples {
      latencySamplesMs.removeFirst(latencySamplesMs.count - Self.maxLatencySamples)
    }
    let total = latencySamplesMs.reduce(0, +)
    connectionMetrics.averageLatencyMs = total / max(latencySamplesMs.count, 1)
  }

  private func appendTrafficSamples(count: Int, at timestamp: Date) {
    for _ in 0..<count {
      trafficSampleTimes.append(timestamp)
    }
    let threshold = timestamp.addingTimeInterval(-Self.trafficWindow)
    trafficSampleTimes.removeAll { $0 < threshold }
    connectionMetrics.messagesPerSecond = Double(trafficSampleTimes.count) / Self.trafficWindow
  }
}
