import SwiftData
import Testing

@testable import HarnessMonitorKit

@MainActor
extension PersistenceSnapshotIntegrationTests {
  @Test("Persistence keeps all cached sessions instead of evicting older snapshots")
  func persistenceKeepsAllCachedSessions() async throws {
    let store = harness.makeStore()

    for index in 0..<55 {
      let session = makeSession(
        .init(
          sessionId: "sess-\(index)",
          context: "Session \(index)",
          status: .active,
          openTaskCount: 0,
          inProgressTaskCount: 0,
          blockedTaskCount: 0,
          activeAgentCount: 0
        ))
      let detail = SessionDetail(
        session: session,
        agents: [],
        tasks: [],
        signals: [],
        observer: nil,
        agentActivity: []
      )
      await store.cacheSessionDetail(detail, timeline: [])
    }

    let descriptor = FetchDescriptor<CachedSession>()
    let remaining = try harness.container.mainContext.fetch(descriptor)
    #expect(remaining.count == 55)
  }

  @Test("loadCachedSessionList returns nil on empty store")
  func loadCachedSessionListReturnsNilWhenEmpty() async {
    let store = harness.makeStore()
    #expect(await store.loadCachedSessionList() == nil)
  }

  @Test("Persisted detail stays loadable even when it was hydrated without manual viewing")
  func loadCachedDetailReturnsHydratedSnapshotWithoutManualViewing() async {
    let store = harness.makeStore()
    let session = makeSession(
      .init(
        sessionId: "hydrated-offline",
        context: "Hydrated offline",
        status: .active,
        leaderId: "leader-offline",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))
    let detail = makeSessionDetail(
      summary: session,
      workerID: "worker-offline",
      workerName: "Offline Worker"
    )

    await store.cacheSessionDetail(detail, timeline: [], markViewed: false)

    let cached = await store.loadCachedSessionDetail(sessionID: "hydrated-offline")
    #expect(cached?.detail.session.sessionId == "hydrated-offline")
    #expect(store.persistedSessionCount == 1)
    #expect(store.lastPersistedSnapshotAt != nil)
  }

  @Test("Selecting a persisted session offline restores cached detail and timeline")
  func selectingPersistedSessionOfflineRestoresCachedSnapshot() async {
    let store = harness.makeStore()
    let project = makeProject(totalSessionCount: 1, activeSessionCount: 1)
    let session = makeSession(
      .init(
        sessionId: "sess-offline-select",
        context: "Offline selection",
        status: .active,
        leaderId: "leader-offline-select",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))
    let detail = makeSessionDetail(
      summary: session,
      workerID: "worker-select",
      workerName: "Offline Select Worker"
    )
    let timeline = makeTimelineEntries(
      sessionID: session.sessionId,
      agentID: detail.agents[0].agentId,
      summary: "Offline timeline snapshot"
    )

    await store.cacheSessionList([session], projects: [project])
    await store.cacheSessionDetail(detail, timeline: timeline, markViewed: false)
    store.connectionState = .offline("daemon down")

    await store.selectSession(session.sessionId)

    #expect(store.selectedSessionID == session.sessionId)
    #expect(store.selectedSession?.session.sessionId == session.sessionId)
    #expect(store.timeline == timeline)
    #expect(store.isShowingCachedData)
    #expect(store.sessionDataAvailability != .live)
  }

  @Test(
    "Selecting an offline persisted session with only a cached summary restores a summary-backed cockpit"
  )
  func selectingPersistedSessionOfflineRestoresSummaryBackedCockpit() async {
    let store = harness.makeStore()
    let project = makeProject(totalSessionCount: 1, activeSessionCount: 1)
    let session = makeSession(
      .init(
        sessionId: "sess-summary-only",
        context: "Summary only selection",
        status: .active,
        leaderId: "leader-summary-only",
        openTaskCount: 2,
        inProgressTaskCount: 1,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))

    store.applySessionIndexSnapshot(projects: [project], sessions: [session])
    store.connectionState = .offline("daemon down")

    await store.selectSession(session.sessionId)

    #expect(store.selectedSessionID == session.sessionId)
    #expect(store.selectedSession?.session == session)
    #expect(store.selectedSession?.agents.isEmpty == true)
    #expect(store.selectedSession?.tasks.isEmpty == true)
    #expect(store.timeline.isEmpty)
    #expect(store.isShowingCachedData)
  }

  @Test("Hydration upgrades the selected summary-backed cockpit when live detail arrives")
  func hydrationUpgradesSelectedSummaryBackedCockpit() async throws {
    let session = makeSession(
      .init(
        sessionId: "sess-hydrate-selected",
        context: "Hydrate selected",
        status: .active,
        leaderId: "leader-hydrate-selected",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))
    let project = makeProject(totalSessionCount: 1, activeSessionCount: 1)
    let detail = makeSessionDetail(
      summary: session,
      workerID: "worker-hydrate-selected",
      workerName: "Hydration Worker"
    )
    let timeline = makeTimelineEntries(
      sessionID: session.sessionId,
      agentID: detail.agents[0].agentId,
      summary: "Hydrated timeline"
    )
    let client = RecordingHarnessClient()
    client.configureSessions(
      summaries: [session],
      detailsByID: [session.sessionId: detail],
      timelinesBySessionID: [session.sessionId: timeline]
    )

    let store = harness.makeStore()
    store.applySessionIndexSnapshot(projects: [project], sessions: [session])
    store.connectionState = .online
    store.primeSessionSelection(session.sessionId)
    await store.restorePersistedSessionSelection(sessionID: session.sessionId)

    #expect(store.selectedSession?.session == session)
    #expect(store.selectedSession?.agents.isEmpty == true)
    #expect(store.isShowingCachedData)

    store.schedulePersistedSnapshotHydration(using: client, sessions: [session])
    try await Task.sleep(for: .milliseconds(100))

    #expect(store.selectedSession == detail)
    #expect(store.timeline == timeline)
    #expect(store.isShowingCachedData == false)
  }

  @Test("Hydration helper detects when a persisted detail snapshot is missing")
  func persistedSnapshotNeedsHydrationReflectsSnapshotState() async {
    let store = harness.makeStore()
    let project = makeProject(totalSessionCount: 1, activeSessionCount: 1)
    let session = makeSession(
      .init(
        sessionId: "sess-hydration",
        context: "Hydration needed",
        status: .active,
        leaderId: "leader-hydration",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))
    let detail = makeSessionDetail(
      summary: session,
      workerID: "worker-hydration",
      workerName: "Hydration Worker"
    )

    await store.cacheSessionList([session], projects: [project])
    #expect(await store.persistedSnapshotHydrationQueue(for: [session]).isEmpty == false)

    let timeline = makeTimelineEntries(
      sessionID: session.sessionId,
      agentID: "leader-hydration",
      summary: "Hydration checkpoint"
    )
    await store.cacheSessionDetail(detail, timeline: timeline, markViewed: false)
    #expect(await store.persistedSnapshotHydrationQueue(for: [session]).isEmpty)
  }
}
