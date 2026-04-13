import Foundation
import SwiftData
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor store lifecycle core")
struct HarnessMonitorStoreLifecycleCoreTests {
  @Test("API client shutdown invalidates the backing URLSession")
  func apiClientShutdownInvalidatesSession() async {
    let probe = SessionInvalidationProbe()
    let session = URLSession(
      configuration: .ephemeral,
      delegate: probe,
      delegateQueue: nil
    )
    let client = HarnessMonitorAPIClient(
      connection: HarnessMonitorConnection(
        endpoint: URL(string: "http://127.0.0.1:9999")!,
        token: "token"
      ),
      session: session
    )

    await client.shutdown()

    for _ in 0..<20 where !probe.didInvalidate {
      try? await Task.sleep(for: .milliseconds(10))
    }

    #expect(probe.didInvalidate)
  }

  @Test("bootstrapIfNeeded only bootstraps once")
  func bootstrapIfNeededOnlyBootstrapsOnce() async {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())

    await store.bootstrapIfNeeded()
    #expect(store.connectionState == .online)

    store.connectionState = .idle

    await store.bootstrapIfNeeded()
    #expect(store.connectionState == .idle)
  }

  @Test("Bootstrap adopts trace as the default daemon log level")
  func bootstrapAdoptsTraceAsDefaultDaemonLogLevel() async {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())

    await store.bootstrap()

    #expect(store.daemonLogLevel == HarnessMonitorLogger.defaultDaemonLogLevel)
  }

  @Test("Start daemon failure sets offline state and error")
  func startDaemonFailureSetsOfflineStateAndError() async {
    let daemon = FailingDaemonController(
      bootstrapError: DaemonControlError.daemonDidNotStart
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.startDaemon()

    #expect(
      store.connectionState
        == .offline(DaemonControlError.daemonDidNotStart.localizedDescription)
    )
    #expect(store.currentFailureFeedbackMessage != nil)
    #expect(store.isDaemonActionInFlight == false)
  }

  @Test("Prime session selection clears detail and timeline")
  func primeSessionSelectionClearsDetailAndTimeline() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)
    #expect(store.selectedSession != nil)
    #expect(store.timeline.isEmpty == false)

    store.primeSessionSelection("different-session")

    #expect(store.selectedSessionID == "different-session")
    #expect(store.selectedSession == nil)
    #expect(store.timeline.isEmpty)
    #expect(store.isSelectionLoading)
    #expect(store.inspectorSelection == .none)
  }

  @Test("Prime session selection with nil clears everything")
  func primeSessionSelectionWithNilClearsEverything() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)

    store.primeSessionSelection(nil)

    #expect(store.selectedSessionID == nil)
    #expect(store.selectedSession == nil)
    #expect(store.timeline.isEmpty)
    #expect(store.isSelectionLoading == false)
  }

  @Test("Prime session selection with same session is a no-op")
  func primeSessionSelectionWithSameSessionIsNoOp() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)
    let originalDetail = store.selectedSession

    store.primeSessionSelection(PreviewFixtures.summary.sessionId)

    #expect(store.selectedSession == originalDetail)
    #expect(store.isSelectionLoading == false)
  }

  @Test("Session selection prefers core detail scope on websocket transport")
  func sessionSelectionPrefersCoreDetailScopeOnWebsocketTransport() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.activeTransport = .webSocket

    await store.selectSession(PreviewFixtures.summary.sessionId)

    #expect(client.sessionDetailScopes(for: PreviewFixtures.summary.sessionId) == ["core"])
  }

  @Test("Session selection keeps full detail scope on HTTP transport")
  func sessionSelectionKeepsFullDetailScopeOnHTTPTransport() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.activeTransport = .httpSSE

    await store.selectSession(PreviewFixtures.summary.sessionId)

    #expect(client.sessionDetailScopes(for: PreviewFixtures.summary.sessionId) == [nil])
  }

  @Test("Session selection prefers summary timeline scope on websocket transport")
  func sessionSelectionPrefersSummaryTimelineScopeOnWebsocketTransport() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.activeTransport = .webSocket

    await store.selectSession(PreviewFixtures.summary.sessionId)

    #expect(client.timelineScopes(for: PreviewFixtures.summary.sessionId) == [.summary])
  }

  @Test("Session selection keeps full timeline scope on HTTP transport")
  func sessionSelectionKeepsFullTimelineScopeOnHTTPTransport() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.activeTransport = .httpSSE

    await store.selectSession(PreviewFixtures.summary.sessionId)

    #expect(client.timelineScopes(for: PreviewFixtures.summary.sessionId) == [.full])
  }

  @Test("Refresh diagnostics without client falls back to daemon status")
  func refreshDiagnosticsWithoutClientFallsBackToDaemonStatus() async {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.diagnostics = nil

    await store.refreshDiagnostics()

    #expect(store.diagnostics == nil)
    #expect(store.isDiagnosticsRefreshInFlight == false)
  }

  @Test("Selecting nil session stops session stream subscription")
  func selectingNilSessionStopsSubscription() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)
    #expect(store.subscribedSessionIDs.isEmpty == false)

    await store.selectSession(nil)

    #expect(store.subscribedSessionIDs.isEmpty)
    #expect(store.selectedSessionID == nil)
  }

  @Test("Superseded selected-session refresh cancels the stale load before timeline fetch")
  func supersededSelectedSessionRefreshCancelsStaleLoadBeforeTimelineFetch() async {
    let summary = makeSession(
      .init(
        sessionId: "sess-refresh-cancel",
        context: "Refresh cancellation",
        status: .active,
        leaderId: "leader-refresh-cancel",
        observeId: nil,
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 2
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-refresh-cancel",
      workerName: "Worker Refresh Cancel"
    )
    let timeline = makeTimelineEntries(
      sessionID: summary.sessionId,
      agentID: "worker-refresh-cancel",
      summary: "Refresh cancellation timeline"
    )
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [summary],
      detailsByID: [summary.sessionId: detail],
      timelinesBySessionID: [summary.sessionId: timeline],
      detail: detail
    )
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(summary.sessionId)

    let baselineDetailCount = client.readCallCount(.sessionDetail(summary.sessionId))
    let baselineTimelineCount = client.readCallCount(.timeline(summary.sessionId))

    client.configureDetailDelay(.milliseconds(200), for: summary.sessionId)

    let firstUpdate = makeUpdatedSession(
      summary,
      context: "Refresh cancellation first",
      updatedAt: "2026-03-28T15:05:00Z",
      agentCount: 2
    )
    let secondUpdate = makeUpdatedSession(
      summary,
      context: "Refresh cancellation second",
      updatedAt: "2026-03-28T15:06:00Z",
      agentCount: 3
    )

    store.refreshSelectedSessionIfSummaryChanged(sessions: [firstUpdate])
    try? await Task.sleep(for: .milliseconds(40))
    store.refreshSelectedSessionIfSummaryChanged(sessions: [secondUpdate])
    try? await Task.sleep(for: .milliseconds(500))

    #expect(client.readCallCount(.sessionDetail(summary.sessionId)) == baselineDetailCount + 2)
    #expect(client.readCallCount(.timeline(summary.sessionId)) == baselineTimelineCount + 1)
  }

}
