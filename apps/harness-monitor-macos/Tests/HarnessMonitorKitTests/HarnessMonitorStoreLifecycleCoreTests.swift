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

  @Test("WebSocket transport shutdown invalidates the backing URLSession")
  func webSocketTransportShutdownInvalidatesSession() async {
    let connection = HarnessMonitorConnection(
      endpoint: URL(string: "http://127.0.0.1:9999")!,
      token: "token"
    )
    let webSocketProbe = SessionInvalidationProbe()
    let webSocketSession = URLSession(
      configuration: .ephemeral,
      delegate: webSocketProbe,
      delegateQueue: nil
    )
    let transport = WebSocketTransport(
      connection: connection,
      session: webSocketSession
    )

    await transport.shutdown()

    for _ in 0..<20 where !webSocketProbe.didInvalidate {
      try? await Task.sleep(for: .milliseconds(10))
    }

    #expect(webSocketProbe.didInvalidate)
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

  @Test("bootstrapIfNeeded survives caller cancellation during external daemon warm-up")
  func bootstrapIfNeededSurvivesCallerCancellationDuringWarmUp() async {
    let daemon = BootstrapBarrierDaemonController()
    let store = HarnessMonitorStore(
      daemonController: daemon,
      daemonOwnership: .external
    )

    let firstCall = Task { @MainActor in
      await store.bootstrapIfNeeded()
    }
    await daemon.waitUntilWarmUpStarted()
    #expect(store.connectionState == .connecting)

    firstCall.cancel()

    let secondCall = Task { @MainActor in
      await store.bootstrapIfNeeded()
    }
    await daemon.releaseWarmUp()

    #expect(await bootstrapTaskCompletes(firstCall, timeout: .seconds(1)))
    #expect(await bootstrapTaskCompletes(secondCall, timeout: .seconds(1)))
    #expect(store.connectionState == .online)
    #expect(await daemon.recordedWarmUpCallCount() == 1)
  }

  @Test("bootstrapIfNeeded coalesces concurrent external warm-up callers")
  func bootstrapIfNeededCoalescesConcurrentWarmUpCallers() async {
    let daemon = BootstrapBarrierDaemonController()
    let store = HarnessMonitorStore(
      daemonController: daemon,
      daemonOwnership: .external
    )

    let firstCall = Task { @MainActor in
      await store.bootstrapIfNeeded()
    }
    await daemon.waitUntilWarmUpStarted()
    let secondCall = Task { @MainActor in
      await store.bootstrapIfNeeded()
    }

    try? await Task.sleep(for: .milliseconds(20))
    #expect(await daemon.recordedWarmUpCallCount() == 1)

    await daemon.releaseWarmUp()

    #expect(await bootstrapTaskCompletes(firstCall, timeout: .seconds(1)))
    #expect(await bootstrapTaskCompletes(secondCall, timeout: .seconds(1)))
    #expect(store.connectionState == .online)
    #expect(await daemon.recordedWarmUpCallCount() == 1)
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

  @Test(
    "Session selection keeps cached signals visible when websocket core detail omits extensions")
  func sessionSelectionKeepsCachedSignalsVisibleWhenWebsocketCoreDetailOmitsExtensions()
    async throws
  {
    let client = RecordingHarnessClient()
    let coreOnlyDetail = SessionDetail(
      session: PreviewFixtures.detail.session,
      agents: PreviewFixtures.detail.agents,
      tasks: PreviewFixtures.detail.tasks,
      signals: [],
      observer: nil,
      agentActivity: []
    )
    client.configureSessions(
      summaries: [PreviewFixtures.summary],
      detailsByID: [PreviewFixtures.summary.sessionId: coreOnlyDetail],
      timelinesBySessionID: [PreviewFixtures.summary.sessionId: PreviewFixtures.timeline]
    )

    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client),
      modelContainer: try HarnessMonitorModelContainer.preview()
    )
    await store.bootstrap()
    store.activeTransport = .webSocket
    await store.cacheSessionDetail(
      PreviewFixtures.detail,
      timeline: PreviewFixtures.timeline,
      markViewed: false
    )

    await store.selectSession(PreviewFixtures.summary.sessionId)

    #expect(client.sessionDetailScopes(for: PreviewFixtures.summary.sessionId) == ["core"])
    #expect(store.selectedSession?.signals == PreviewFixtures.signals)
    #expect(
      store.contentUI.sessionDetail.presentedSessionDetail?.signals == PreviewFixtures.signals)
  }

  @Test("Session selection keeps full detail scope on HTTP transport")
  func sessionSelectionKeepsFullDetailScopeOnHTTPTransport() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.activeTransport = .httpSSE

    await store.selectSession(PreviewFixtures.summary.sessionId)

    #expect(client.sessionDetailScopes(for: PreviewFixtures.summary.sessionId) == [nil])
  }

  @Test("Missing selected session detail prunes the stale session locally")
  func missingSelectedSessionDetailPrunesStaleSessionLocally() async {
    let client = RecordingHarnessClient()
    client.configureSessionDetailError(
      HarnessMonitorAPIError.server(
        code: 400,
        message:
          "session not active: session '\(PreviewFixtures.summary.sessionId)' not found"
      ),
      for: PreviewFixtures.summary.sessionId
    )
    let store = await makeBootstrappedStore(client: client)

    await store.selectSession(PreviewFixtures.summary.sessionId)

    #expect(store.selectedSessionID == nil)
    #expect(store.selectedSession == nil)
    #expect(store.selectedSessionSummary == nil)
    #expect(store.sessions.isEmpty)
    #expect(store.contentUI.session.selectedSessionSummary == nil)
    #expect(store.contentUI.sessionDetail.presentedSessionDetail == nil)
  }

  @Test("Session selection prefers summary timeline scope on websocket transport")
  func sessionSelectionPrefersSummaryTimelineScopeOnWebsocketTransport() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.activeTransport = .webSocket

    await store.selectSession(PreviewFixtures.summary.sessionId)

    #expect(client.timelineScopes(for: PreviewFixtures.summary.sessionId) == [.summary])
  }

  @Test("Session selection prefers summary timeline scope on HTTP transport")
  func sessionSelectionPrefersSummaryTimelineScopeOnHTTPTransport() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.activeTransport = .httpSSE

    await store.selectSession(PreviewFixtures.summary.sessionId)

    #expect(client.timelineScopes(for: PreviewFixtures.summary.sessionId) == [.summary])
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
}
