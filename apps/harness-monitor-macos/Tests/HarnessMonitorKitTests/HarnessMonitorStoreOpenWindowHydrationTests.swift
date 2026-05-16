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

  func testHydrationFetchesAndRegistersUnknownSessionSummary() async throws {
    let harness = try PersistenceIntegrationTestHarness()
    let session = makeSession(.freshlyCreatedActive)
    let detail = makeSessionDetail(
      summary: session,
      workerID: "worker-new-session",
      workerName: "New Session Worker"
    )
    let client = RecordingHarnessClient()
    client.configureSessions(
      summaries: [],
      detailsByID: [session.sessionId: detail],
      timelinesBySessionID: [session.sessionId: []]
    )
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client),
      voiceCapture: NativeVoiceCaptureService(),
      modelContainer: harness.container
    )
    store.connectionState = .online
    store.client = client

    XCTAssertNil(store.sessionIndex.sessionSummary(for: session.sessionId))

    await store.ensureSessionDetailHydratedForOpenWindow(sessionID: session.sessionId)
    await store.flushPendingCacheWrite()

    XCTAssertEqual(client.readCallCount(.sessionDetail(session.sessionId)), 1)
    XCTAssertNotNil(store.sessionIndex.sessionSummary(for: session.sessionId))
    let cachedDetail = await store.loadCachedSessionDetail(sessionID: session.sessionId)
    XCTAssertEqual(cachedDetail?.detail.session.sessionId, session.sessionId)
  }

  func testHydrationKeepsNewSessionInRestartRestorePlan() async throws {
    let harness = try PersistenceIntegrationTestHarness()
    let existingSession = makeSession(.unhydratedActive)
    let newSession = makeSession(.freshlyCreatedActive)
    let newDetail = makeSessionDetail(
      summary: newSession,
      workerID: "worker-restart-new-session",
      workerName: "Restart New Session Worker"
    )
    let client = RecordingHarnessClient()
    client.configureSessions(
      summaries: [existingSession],
      detailsByID: [newSession.sessionId: newDetail],
      timelinesBySessionID: [newSession.sessionId: []]
    )
    let cacheService = SessionCacheService(modelContainer: harness.container)
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client),
      voiceCapture: NativeVoiceCaptureService(),
      modelContainer: harness.container
    )
    store.sessionIndex.replaceSnapshot(projects: [], sessions: [existingSession])
    store.connectionState = .online
    store.client = client
    await store.cacheSessionSummary(existingSession, project: nil)

    await store.ensureSessionDetailHydratedForOpenWindow(sessionID: newSession.sessionId)
    await store.flushPendingCacheWrite()
    _ = await cacheService.replaceSessionWindowsOpenAtQuit(
      snapshot: HarnessMonitorStore.SessionWindowQuitSnapshot(
        sessionIDs: Set([existingSession.sessionId, newSession.sessionId]),
        groupings: [
          HarnessMonitorStore.SessionTabGroupSnapshot(
            ordinal: 0,
            sessionIDs: [existingSession.sessionId, newSession.sessionId],
            foregroundSessionID: existingSession.sessionId
          )
        ]
      )
    )

    let relaunchedStore = harness.makeStore()
    await relaunchedStore.prepareOpenRecentSessions()

    let restorePlan = await relaunchedStore.launchWindowRestorePlan()

    XCTAssertEqual(
      restorePlan.sessionIDs,
      [existingSession.sessionId, newSession.sessionId]
    )
    XCTAssertEqual(
      restorePlan.tabGroupings,
      [
        HarnessMonitorStore.SessionTabGroupSnapshot(
          ordinal: 0,
          sessionIDs: [existingSession.sessionId, newSession.sessionId],
          foregroundSessionID: existingSession.sessionId
        )
      ]
    )
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

  fileprivate static let freshlyCreatedActive = SessionFixture(
    sessionId: "sess-open-window-newly-created",
    context: "Freshly created session",
    status: .active,
    leaderId: "leader-new-session",
    openTaskCount: 0,
    inProgressTaskCount: 0,
    blockedTaskCount: 0,
    activeAgentCount: 1
  )
}
