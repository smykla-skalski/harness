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

  @Test("API client timeline summary scope adds the HTTP query parameter")
  func apiClientTimelineSummaryScopeAddsHTTPQueryParameter() async throws {
    SummaryTimelineURLProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SummaryTimelineURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = HarnessMonitorAPIClient(
      connection: HarnessMonitorConnection(
        endpoint: URL(string: "http://127.0.0.1:9999")!,
        token: "token"
      ),
      session: session
    )

    let entries = try await client.timeline(sessionID: "sess-http-summary", scope: .summary)

    #expect(entries.count == 1)
    #expect(
      SummaryTimelineURLProtocol.lastRequestURL?.path
        == "/v1/sessions/sess-http-summary/timeline"
    )
    #expect(SummaryTimelineURLProtocol.lastRequestURL?.query == "scope=summary")
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

  @Test("Superseded selected-session refreshes coalesce into one fallback load")
  func supersededSelectedSessionRefreshesCoalesceIntoOneFallbackLoad() async {
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
    store.selectedSessionRefreshFallbackDelay = .milliseconds(120)
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
    try? await Task.sleep(for: .milliseconds(360))

    #expect(store.selectedSession?.session.context == secondUpdate.context)
    #expect(client.readCallCount(.sessionDetail(summary.sessionId)) == baselineDetailCount + 1)
    #expect(client.readCallCount(.timeline(summary.sessionId)) == baselineTimelineCount + 1)
  }

  @Test("Summary refresh during selection load keeps the selected session stream attached")
  func summaryRefreshDuringSelectionLoadKeepsSelectedSessionStreamAttached() async throws {
    let summary = makeSession(
      .init(
        sessionId: "sess-refresh-stream",
        context: "Refresh stream baseline",
        status: .active,
        leaderId: "leader-refresh-stream",
        observeId: "observe-refresh-stream",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))
    let updatedSummary = makeUpdatedSession(
      summary,
      context: "Refresh stream updated",
      updatedAt: "2026-03-28T15:07:00Z",
      agentCount: 2
    )
    let initialDetail = makeSessionDetail(
      summary: summary,
      workerID: "worker-refresh-stream-before",
      workerName: "Worker Refresh Stream Before"
    )
    let updatedDetail = makeSessionDetail(
      summary: updatedSummary,
      workerID: "worker-refresh-stream-after",
      workerName: "Worker Refresh Stream After"
    )
    let refreshedTimeline = makeTimelineEntries(
      sessionID: summary.sessionId,
      agentID: "worker-refresh-stream-after",
      summary: "Refresh stream timeline"
    )
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [summary],
      detailsByID: [summary.sessionId: initialDetail],
      timelinesBySessionID: [summary.sessionId: refreshedTimeline],
      detail: initialDetail
    )
    client.configureSessionStream(events: [], for: summary.sessionId)
    client.configureDetailDelay(.milliseconds(200), for: summary.sessionId)
    let store = await makeBootstrappedStore(client: client)

    let selectionTask = Task {
      await store.selectSession(summary.sessionId)
    }
    try await Task.sleep(for: .milliseconds(40))

    client.configureSessions(
      summaries: [updatedSummary],
      detailsByID: [summary.sessionId: updatedDetail],
      timelinesBySessionID: [summary.sessionId: refreshedTimeline]
    )
    store.refreshSelectedSessionIfSummaryChanged(sessions: [updatedSummary])

    await selectionTask.value
    while let sessionLoadTask = store.sessionLoadTask {
      await sessionLoadTask.value
    }

    #expect(store.selectedSession?.session.context == updatedSummary.context)
    #expect(store.subscribedSessionIDs == Set([summary.sessionId]))
    #expect(store.sessionStreamTask != nil)
  }

}

private final class SummaryTimelineURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var requestURL: URL?

  static var lastRequestURL: URL? {
    lock.withLock { requestURL }
  }

  static func reset() {
    lock.withLock {
      requestURL = nil
    }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let requestURL = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }

    Self.lock.withLock {
      Self.requestURL = requestURL
    }

    guard
      let response = HTTPURLResponse(
        url: requestURL,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    let data = Data(
      """
      [{"entry_id":"entry-1","recorded_at":"2026-04-14T03:00:00Z","kind":"tool_result","session_id":"sess-http-summary","agent_id":null,"task_id":null,"summary":"Summary entry","payload":{}}]
      """.utf8
    )
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
