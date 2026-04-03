import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor store connection metrics")
struct HarnessMonitorStoreMetricsTests {
  @Test("Bootstrap records a real latency sample")
  func bootstrapRecordsLatencySample() async {
    let client = RecordingHarnessClient()
    client.configureHealthDelay(.milliseconds(25))
    client.configureTransportLatencyMs(87)

    let store = await makeBootstrappedStore(client: client)

    #expect(store.connectionMetrics.latencyMs == 87)
    #expect(store.connectionMetrics.averageLatencyMs == 87)
    #expect(store.connectionMetrics.connectedSince != nil)
    #expect(client.readCallCount(.transportLatency) > 0)

    store.stopAllStreams()
  }

  @Test("Latency probe restores a missing sample while connected")
  func latencyProbeRestoresMissingSample() async {
    let client = RecordingHarnessClient()
    client.configureHealthDelay(.milliseconds(20))
    client.configureTransportLatencyMs(143)

    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client)
    )
    store.connectionProbeInterval = .milliseconds(30)

    await store.bootstrap()
    store.connectionMetrics.latencyMs = nil
    store.connectionMetrics.averageLatencyMs = nil

    try? await Task.sleep(for: .milliseconds(120))

    #expect(store.connectionMetrics.latencyMs == 143)
    #expect(store.connectionMetrics.averageLatencyMs == 143)
    #expect(client.readCallCount(.transportLatency) > 1)

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
      error: HarnessMonitorAPIError.server(code: 500, message: "stream failed")
    )

    let store = await makeBootstrappedStore(client: client)

    try? await Task.sleep(for: .milliseconds(60))

    #expect(store.connectionMetrics.reconnectCount == 1)
    #expect(store.connectionMetrics.reconnectAttempt == 1)

    store.stopAllStreams()
  }

  private func makeEvent(name: String, sessionID: String?) -> DaemonPushEvent {
    switch name {
    case "ready":
      .ready(recordedAt: "2026-03-31T12:00:00Z", sessionId: sessionID)
    case "sessions_updated":
      .sessionsUpdated(
        recordedAt: "2026-03-31T12:00:00Z",
        projects: PreviewFixtures.projects,
        sessions: [PreviewFixtures.summary]
      )
    default:
      .sessionUpdated(
        recordedAt: "2026-03-31T12:00:00Z",
        sessionId: sessionID ?? PreviewFixtures.summary.sessionId,
        detail: PreviewFixtures.detail,
        timeline: PreviewFixtures.timeline
      )
    }
  }
}
