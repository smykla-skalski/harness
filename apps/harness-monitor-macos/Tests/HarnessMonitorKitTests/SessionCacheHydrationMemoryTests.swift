import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Session cache hydration memory fixes")
struct SessionCacheHydrationMemoryTests {
  let harness: SessionCacheMemoryTestHarness

  init() throws {
    harness = try SessionCacheMemoryTestHarness()
  }

  @Test("Hydration queue detects detail via timeline entries, not relationships")
  func hydrationQueueDetectsDetailViaTimelineEntries() async throws {
    let store = harness.makeStore()
    let project = makeProject(totalSessionCount: 1, activeSessionCount: 1)
    let session = makeSession(
      .init(
        sessionId: "sess-detect",
        context: "Detection test",
        status: .active,
        leaderId: "leader-detect",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))

    await store.cacheSessionList([session], projects: [project])

    let needsHydration = await store.persistedSnapshotHydrationQueue(
      for: [session]
    )
    #expect(!needsHydration.isEmpty)

    let detail = makeSessionDetail(
      summary: session,
      workerID: "worker-detect",
      workerName: "Detect Worker"
    )
    let timeline = makeTimelineEntries(
      sessionID: "sess-detect",
      agentID: "leader-detect",
      summary: "Checkpoint"
    )
    await store.cacheSessionDetail(detail, timeline: timeline)

    let afterHydration = await store.persistedSnapshotHydrationQueue(
      for: [session]
    )
    #expect(afterHydration.isEmpty)
  }

  @Test("Hydration queue detects session without timeline as needing hydration")
  func hydrationQueueDetectsNoTimeline() async throws {
    let store = harness.makeStore()
    let project = makeProject(totalSessionCount: 1, activeSessionCount: 1)
    let session = makeSession(
      .init(
        sessionId: "sess-notimeline",
        context: "No timeline",
        status: .active,
        leaderId: "leader-notimeline",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))

    await store.cacheSessionList([session], projects: [project])
    let detail = SessionDetail(
      session: session,
      agents: [],
      tasks: [],
      signals: [],
      observer: nil,
      agentActivity: []
    )
    await store.cacheSessionDetail(detail, timeline: [])

    let queue = await store.persistedSnapshotHydrationQueue(for: [session])
    #expect(!queue.isEmpty)
  }

  @Test("Hydration queue skips sessions with cached timeline even when summaries advance")
  func hydrationQueueSkipsStaleSummariesWhenTimelineExists() async throws {
    let store = harness.makeStore()
    let project = makeProject(totalSessionCount: 1, activeSessionCount: 1)
    let session = makeSession(
      .init(
        sessionId: "sess-stale-summary",
        context: "Stale summary",
        status: .active,
        leaderId: "leader-stale-summary",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))

    await store.cacheSessionList([session], projects: [project])

    let detail = makeSessionDetail(
      summary: session,
      workerID: "worker-stale-summary",
      workerName: "Worker"
    )
    let timeline = makeTimelineEntries(
      sessionID: session.sessionId,
      agentID: session.leaderId ?? "",
      summary: "Cached entry"
    )
    await store.cacheSessionDetail(detail, timeline: timeline)

    let updatedSession = SessionSummary(
      projectId: session.projectId,
      projectName: session.projectName,
      projectDir: session.projectDir,
      contextRoot: session.contextRoot,
      sessionId: session.sessionId,
      title: session.title,
      context: "Stale summary updated",
      status: session.status,
      createdAt: session.createdAt,
      updatedAt: "2026-04-03T00:00:00Z",
      lastActivityAt: "2026-04-03T00:00:00Z",
      leaderId: session.leaderId,
      observeId: session.observeId,
      pendingLeaderTransfer: session.pendingLeaderTransfer,
      metrics: session.metrics
    )

    let queue = await store.persistedSnapshotHydrationQueue(for: [updatedSession])
    #expect(queue.isEmpty)
  }

  @Test("Hydration queue only checks sessions matching input")
  func hydrationQueueScopedToInput() async throws {
    let store = harness.makeStore()
    let project = makeProject(totalSessionCount: 3, activeSessionCount: 3)

    let sessions = (0..<3).map { index in
      makeSession(
        .init(
          sessionId: "sess-scope-\(index)",
          context: "Scope \(index)",
          status: .active,
          openTaskCount: 0,
          inProgressTaskCount: 0,
          blockedTaskCount: 0,
          activeAgentCount: 1
        ))
    }

    await store.cacheSessionList(sessions, projects: [project])

    let subset = [sessions[1]]
    let queue = await store.persistedSnapshotHydrationQueue(for: subset)
    #expect(queue.count == 1)
    #expect(queue.first?.sessionId == "sess-scope-1")
  }

  @Test("Hydration scoped to recently viewed sessions")
  func hydrationScopedToRecentlyViewed() async throws {
    let store = harness.makeStore()
    let project = makeProject(totalSessionCount: 3, activeSessionCount: 3)

    let sessions = (0..<3).map { index in
      makeSession(
        .init(
          sessionId: "sess-recent-\(index)",
          context: "Recent \(index)",
          status: .active,
          leaderId: "leader-recent-\(index)",
          openTaskCount: 0,
          inProgressTaskCount: 0,
          blockedTaskCount: 0,
          activeAgentCount: 1
        ))
    }

    await store.cacheSessionList(sessions, projects: [project])

    for session in sessions {
      let detail = makeSessionDetail(
        summary: session,
        workerID: "worker-\(session.sessionId)",
        workerName: "Worker"
      )
      let timeline = makeTimelineEntries(
        sessionID: session.sessionId,
        agentID: session.leaderId ?? "",
        summary: "Entry"
      )
      await store.cacheSessionDetail(
        detail,
        timeline: timeline,
        markViewed: session.sessionId == "sess-recent-1"
      )
    }

    var detailsByID: [String: SessionDetail] = [:]
    var timelinesByID: [String: [TimelineEntry]] = [:]
    for session in sessions {
      detailsByID[session.sessionId] = makeSessionDetail(
        summary: session,
        workerID: "worker-\(session.sessionId)",
        workerName: "Worker"
      )
      timelinesByID[session.sessionId] = makeTimelineEntries(
        sessionID: session.sessionId,
        agentID: session.leaderId ?? "",
        summary: "Updated entry"
      )
    }

    let client = RecordingHarnessClient()
    client.configureSessions(
      summaries: sessions,
      detailsByID: detailsByID,
      timelinesBySessionID: timelinesByID
    )

    let updatedSessions = sessions.map { original in
      SessionSummary(
        projectId: original.projectId,
        projectName: original.projectName,
        projectDir: original.projectDir,
        contextRoot: original.contextRoot,
        sessionId: original.sessionId,
        title: original.title,
        context: original.context,
        status: original.status,
        createdAt: original.createdAt,
        updatedAt: "2026-04-02T00:00:00Z",
        lastActivityAt: "2026-04-02T00:00:00Z",
        leaderId: original.leaderId,
        observeId: original.observeId,
        pendingLeaderTransfer: original.pendingLeaderTransfer,
        metrics: original.metrics
      )
    }

    store.connectionState = .online
    store.schedulePersistedSnapshotHydration(
      using: client,
      sessions: updatedSessions
    )
    try await Task.sleep(for: .milliseconds(200))

    let totalDetailCalls =
      client.readCallCount(.sessionDetail("sess-recent-0"))
      + client.readCallCount(.sessionDetail("sess-recent-1"))
      + client.readCallCount(.sessionDetail("sess-recent-2"))

    #expect(totalDetailCalls <= 1)

    #expect(client.readCallCount(.sessionDetail("sess-recent-0")) == 0)
    #expect(client.readCallCount(.sessionDetail("sess-recent-2")) == 0)
  }

  @Test("Batch cacheSessionDetails persists all entries under a single save")
  func batchCacheSessionDetailsPersistsAllEntries() async throws {
    let store = harness.makeStore()
    let project = makeProject(totalSessionCount: 3, activeSessionCount: 3)

    let sessions = (0..<3).map { index in
      makeSession(
        .init(
          sessionId: "sess-batch-\(index)",
          context: "Batch \(index)",
          status: .active,
          leaderId: "leader-batch-\(index)",
          openTaskCount: 0,
          inProgressTaskCount: 0,
          blockedTaskCount: 0,
          activeAgentCount: 1
        ))
    }

    await store.cacheSessionList(sessions, projects: [project])

    let entries: [(detail: SessionDetail, timeline: [TimelineEntry])] = sessions.map { summary in
      (
        detail: makeSessionDetail(
          summary: summary,
          workerID: "worker-\(summary.sessionId)",
          workerName: "Worker"
        ),
        timeline: makeTimelineEntries(
          sessionID: summary.sessionId,
          agentID: summary.leaderId ?? "",
          summary: "Batch entry"
        )
      )
    }

    await store.cacheSessionDetails(entries, markViewed: false)

    for summary in sessions {
      let cached = await store.loadCachedSessionDetail(sessionID: summary.sessionId)
      #expect(cached != nil)
      #expect(cached?.detail.agents.count == 2)
      #expect(cached?.timeline.first?.summary == "Batch entry")
    }

    let queue = await store.persistedSnapshotHydrationQueue(for: sessions)
    #expect(queue.isEmpty)
  }

  @Test("Batch cacheSessionDetails upserts existing rows and diffs relationships")
  func batchCacheSessionDetailsUpsertsExistingRows() async throws {
    let store = harness.makeStore()
    let project = makeProject(totalSessionCount: 2, activeSessionCount: 2)

    let sessions = (0..<2).map { index in
      makeSession(
        .init(
          sessionId: "sess-upsert-\(index)",
          context: "Upsert \(index)",
          status: .active,
          leaderId: "leader-upsert-\(index)",
          openTaskCount: 0,
          inProgressTaskCount: 0,
          blockedTaskCount: 0,
          activeAgentCount: 1
        ))
    }

    await store.cacheSessionList(sessions, projects: [project])

    let initialEntries: [(detail: SessionDetail, timeline: [TimelineEntry])] = sessions.map {
      (
        detail: makeSessionDetail(
          summary: $0,
          workerID: "worker-\($0.sessionId)",
          workerName: "Worker v1"
        ),
        timeline: makeTimelineEntries(
          sessionID: $0.sessionId,
          agentID: $0.leaderId ?? "",
          summary: "First entry"
        )
      )
    }

    await store.cacheSessionDetails(initialEntries, markViewed: false)

    let updatedEntries: [(detail: SessionDetail, timeline: [TimelineEntry])] = sessions.map {
      (
        detail: makeSessionDetail(
          summary: $0,
          workerID: "worker-\($0.sessionId)-new",
          workerName: "Worker v2"
        ),
        timeline: makeTimelineEntries(
          sessionID: $0.sessionId,
          agentID: $0.leaderId ?? "",
          summary: "Updated entry"
        )
      )
    }

    await store.cacheSessionDetails(updatedEntries, markViewed: false)

    for summary in sessions {
      let cached = await store.loadCachedSessionDetail(sessionID: summary.sessionId)
      #expect(cached != nil)
      #expect(cached?.detail.agents.contains { $0.name == "Worker v2" } == true)
      #expect(cached?.detail.agents.contains { $0.name == "Worker v1" } == false)
      #expect(cached?.timeline.first?.summary == "Updated entry")
    }
  }
}
