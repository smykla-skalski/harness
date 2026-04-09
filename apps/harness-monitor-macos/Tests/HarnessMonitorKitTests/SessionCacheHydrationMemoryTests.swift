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
}
