import XCTest

@testable import HarnessMonitorKit

@MainActor
final class HarnessMonitorStoreOpenWindowHydrationTests: XCTestCase {
  func testHydrationFetchesAndCachesDetailWhenCacheMisses() async throws {
    let harness = try PersistenceIntegrationTestHarness()
    let session = makeSession(.unhydratedActive)
    let detail = makeSessionDetail(
      summary: session,
      workerID: "worker-hydration",
      workerName: "Hydration Worker"
    )
    let client = RecordingHarnessClient()
    client.configureSessions(
      summaries: [session],
      detailsByID: [session.sessionId: detail],
      timelinesBySessionID: [session.sessionId: []]
    )
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client),
      voiceCapture: NativeVoiceCaptureService(),
      modelContainer: harness.container
    )
    store.sessionIndex.replaceSnapshot(projects: [], sessions: [session])
    store.connectionState = .online
    store.client = client

    let cachedBefore = await store.loadCachedSessionDetail(sessionID: session.sessionId)
    XCTAssertNil(cachedBefore, "Precondition: cache must be empty before hydration")

    await store.ensureSessionDetailHydratedForOpenWindow(sessionID: session.sessionId)
    await store.flushPendingCacheWrite()

    let cachedAfter = await store.loadCachedSessionDetail(sessionID: session.sessionId)
    XCTAssertNotNil(cachedAfter, "Hydration must populate cache for an open-window session")
    XCTAssertEqual(cachedAfter?.detail.session.sessionId, session.sessionId)
    XCTAssertEqual(client.readCallCount(.sessionDetail(session.sessionId)), 1)
  }

  func testHydrationIsIdempotentWhenCacheAlreadyHasDetail() async throws {
    let harness = try PersistenceIntegrationTestHarness()
    let session = makeSession(.unhydratedActive)
    let detail = makeSessionDetail(
      summary: session,
      workerID: "worker-noop",
      workerName: "Noop Worker"
    )
    let client = RecordingHarnessClient(detail: detail)
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client),
      voiceCapture: NativeVoiceCaptureService(),
      modelContainer: harness.container
    )
    store.sessionIndex.replaceSnapshot(projects: [], sessions: [session])
    store.connectionState = .online
    store.client = client
    await store.cacheSessionDetail(detail, timeline: [], markViewed: false)

    await store.ensureSessionDetailHydratedForOpenWindow(sessionID: session.sessionId)

    XCTAssertEqual(
      client.readCallCount(.sessionDetail(session.sessionId)),
      0,
      "Hydration must not refetch when the cache already has detail"
    )
  }

  func testHydrationIsNoopWhenSessionSummaryUnknown() async throws {
    let harness = try PersistenceIntegrationTestHarness()
    let client = RecordingHarnessClient()
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client),
      voiceCapture: NativeVoiceCaptureService(),
      modelContainer: harness.container
    )
    store.connectionState = .online
    store.client = client

    await store.ensureSessionDetailHydratedForOpenWindow(sessionID: "sess-unknown")

    XCTAssertEqual(client.readCallCount(.sessionDetail("sess-unknown")), 0)
  }
}

extension SessionFixture {
  fileprivate static let unhydratedActive = SessionFixture(
    sessionId: "sess-open-window-hydration",
    context: "Open window hydration",
    status: .active,
    leaderId: "leader-hydration",
    openTaskCount: 1,
    inProgressTaskCount: 0,
    blockedTaskCount: 0,
    activeAgentCount: 2
  )
}
