import Testing

@testable import HarnessKit

@MainActor
@Suite("Harness store connection metrics")
struct HarnessStoreConnectionMetricsTests {
  @Test("Bootstrap records a real latency sample")
  func bootstrapRecordsLatencySample() async {
    let client = RecordingHarnessClient()
    client.configureHealthDelay(.milliseconds(25))

    let store = await makeBootstrappedStore(client: client)

    #expect((store.connectionMetrics.latencyMs ?? 0) > 0)
    #expect((store.connectionMetrics.averageLatencyMs ?? 0) > 0)
    #expect(store.connectionMetrics.connectedSince != nil)

    store.stopAllStreams()
  }

  @Test("Latency probe restores a missing sample while connected")
  func latencyProbeRestoresMissingSample() async {
    let client = RecordingHarnessClient()
    client.configureHealthDelay(.milliseconds(20))

    let store = HarnessStore(
      daemonController: RecordingDaemonController(client: client)
    )
    store.connectionProbeInterval = .milliseconds(30)

    await store.bootstrap()
    store.connectionMetrics.latencyMs = nil
    store.connectionMetrics.averageLatencyMs = nil

    try? await Task.sleep(for: .milliseconds(120))

    #expect((store.connectionMetrics.latencyMs ?? 0) > 0)
    #expect((store.connectionMetrics.averageLatencyMs ?? 0) > 0)

    store.stopAllStreams()
  }

  @Test("Global stream traffic updates message metrics")
  func globalStreamTrafficUpdatesMessageMetrics() async {
    let client = RecordingHarnessClient()
    client.configureGlobalStream(
      events: [
        makeEvent(name: "ready", sessionID: nil),
        makeEvent(name: "session_updated", sessionID: PreviewFixtures.summary.sessionId),
      ]
    )

    let store = await makeBootstrappedStore(client: client)

    try? await Task.sleep(for: .milliseconds(60))

    #expect(store.connectionMetrics.messagesReceived > 4)
    #expect(store.connectionMetrics.lastMessageAt != nil)
    #expect(store.connectionMetrics.messagesPerSecond > 0)

    store.stopAllStreams()
  }

  @Test("Stream failures increment reconnect metrics")
  func streamFailuresIncrementReconnectMetrics() async {
    let client = RecordingHarnessClient()
    client.configureGlobalStream(
      events: [makeEvent(name: "ready", sessionID: nil)],
      error: HarnessAPIError.server(code: 500, message: "stream failed")
    )

    let store = await makeBootstrappedStore(client: client)

    try? await Task.sleep(for: .milliseconds(60))

    #expect(store.connectionMetrics.reconnectCount == 1)
    #expect(store.connectionMetrics.reconnectAttempt == 1)

    store.stopAllStreams()
  }

  private func makeEvent(name: String, sessionID: String?) -> StreamEvent {
    StreamEvent(
      event: name,
      recordedAt: "2026-03-31T12:00:00Z",
      sessionId: sessionID,
      payload: .object([:])
    )
  }
}
