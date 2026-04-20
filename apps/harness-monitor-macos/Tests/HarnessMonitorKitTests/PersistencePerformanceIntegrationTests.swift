import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Persistence performance integration")
struct PersistencePerformanceIntegrationTests {
  let harness: PersistenceIntegrationTestHarness

  init() throws {
    harness = try PersistenceIntegrationTestHarness()
  }

  @Test("Performance budget: caching a 72-session snapshot stays under 90 ms median")
  func cacheSessionListStaysWithinPerformanceBudget() async throws {
    let fixture = harness.largeSnapshotFixture()
    let medianMs = try await harness.medianRuntimeMs {
      let container = try HarnessMonitorModelContainer.preview()
      let store = HarnessMonitorStore(
        daemonController: RecordingDaemonController(),
        modelContainer: container
      )
      await store.cacheSessionList(fixture.sessions, projects: fixture.projects)
      let cached = await store.loadCachedSessionList()
      #expect(cached?.sessions.count == fixture.sessions.count)
      #expect(cached?.projects.count == fixture.projects.count)
    }

    #expect(medianMs <= 90)
  }

  @Test("Performance budget: session-summary persistence fan-out stays under 45 ms median")
  func sessionSummaryUpdateStaysWithinPerformanceBudget() async throws {
    let fixture = harness.largeSnapshotFixture()
    let container = try HarnessMonitorModelContainer.preview()
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      modelContainer: container
    )
    store.applySessionIndexSnapshot(
      projects: fixture.projects,
      sessions: fixture.sessions
    )
    await store.cacheSessionList(fixture.sessions, projects: fixture.projects)

    var iteration = 0
    let medianMs = await harness.medianRuntimeMs {
      let baseline = fixture.sessions[0]
      iteration += 1
      let updated = SessionSummary(
        projectId: baseline.projectId,
        projectName: baseline.projectName,
        projectDir: baseline.projectDir,
        contextRoot: baseline.contextRoot,
        sessionId: baseline.sessionId,
        worktreePath: baseline.worktreePath,
        sharedPath: baseline.sharedPath,
        originPath: baseline.originPath,
        branchRef: baseline.branchRef,
        title: "Regression 0-0 iter \(iteration)",
        context: "Regression lane 0-0 iteration \(iteration)",
        status: iteration.isMultiple(of: 2) ? .ended : .active,
        createdAt: baseline.createdAt,
        updatedAt: String(format: "2026-04-28T14:%02d:00Z", iteration % 60),
        lastActivityAt: String(format: "2026-04-28T14:%02d:00Z", iteration % 60),
        leaderId: baseline.leaderId,
        observeId: baseline.observeId,
        pendingLeaderTransfer: baseline.pendingLeaderTransfer,
        metrics: SessionMetrics(
          agentCount: baseline.metrics.agentCount,
          activeAgentCount: iteration.isMultiple(of: 2) ? 0 : baseline.metrics.activeAgentCount,
          openTaskCount: iteration % 5,
          inProgressTaskCount: iteration % 4,
          blockedTaskCount: iteration % 3,
          completedTaskCount: baseline.metrics.completedTaskCount + iteration
        )
      )
      store.sessionIndex.applySessionSummary(updated)
      let project = store.sessionIndex.projects.first { $0.projectId == updated.projectId }
      await store.cacheSessionSummary(updated, project: project)
      let cached = await store.loadCachedSessionList()
      let summary = cached?.sessions.first { $0.sessionId == updated.sessionId }
      #expect(summary?.updatedAt == updated.updatedAt)
    }

    #expect(medianMs <= 45)
  }

  @Test("Performance budget: refreshing an unchanged 72-session snapshot stays under 12 ms median")
  func unchangedSnapshotRefreshStaysWithinPerformanceBudget() async throws {
    let fixture = harness.largeSnapshotFixture()
    let container = try HarnessMonitorModelContainer.preview()
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      modelContainer: container
    )
    store.applySessionIndexSnapshot(
      projects: fixture.projects,
      sessions: fixture.sessions
    )

    let medianMs = await harness.medianRuntimeMs {
      store.applySessionIndexSnapshot(
        projects: fixture.projects,
        sessions: fixture.sessions
      )
      #expect(store.sessions.count == fixture.sessions.count)
      #expect(store.projects.count == fixture.projects.count)
    }

    #expect(medianMs <= 12)
  }

  @Test("Performance budget: search projection over 72 sessions stays under 12 ms median")
  func searchProjectionStaysWithinPerformanceBudget() async throws {
    let fixture = harness.largeSnapshotFixture()
    let container = try HarnessMonitorModelContainer.preview()
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      modelContainer: container
    )
    store.applySessionIndexSnapshot(
      projects: fixture.projects,
      sessions: fixture.sessions
    )

    let queries = [
      "Regression 0",
      "leader-2",
      "observe-3",
      "sess0004",
    ]
    var iteration = 0

    let medianMs = await harness.medianRuntimeMs {
      let query = queries[iteration % queries.count]
      iteration += 1
      store.searchText = query
      store.flushPendingSearchRebuild()
      #expect(store.visibleSessionIDs.isEmpty == false)
    }

    #expect(medianMs <= 12)
  }

  @Test("Performance budget: reapplying an unchanged session summary stays under 8 ms median")
  func unchangedSessionSummaryUpdateStaysWithinPerformanceBudget() async throws {
    let fixture = harness.largeSnapshotFixture()
    let container = try HarnessMonitorModelContainer.preview()
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      modelContainer: container
    )
    store.applySessionIndexSnapshot(
      projects: fixture.projects,
      sessions: fixture.sessions
    )
    let baseline = fixture.sessions[0]

    let medianMs = await harness.medianRuntimeMs {
      store.applySessionSummaryUpdate(baseline)
      #expect(store.sessions.first(where: { $0.sessionId == baseline.sessionId }) == baseline)
    }

    #expect(medianMs <= 8)
  }

  @Test("Performance budget: refreshing a 72-session live snapshot stays under 160 ms median")
  func refreshLargeSnapshotStaysWithinPerformanceBudget() async throws {
    let fixture = harness.largeSnapshotFixture()
    let medianMs = try await harness.medianRuntimeMs {
      let container = try HarnessMonitorModelContainer.preview()
      let client = RecordingHarnessClient()
      client.configureSessions(
        summaries: fixture.sessions,
        detailsByID: fixture.detailsByID
      )
      let store = HarnessMonitorStore(
        daemonController: RecordingDaemonController(client: client),
        modelContainer: container
      )
      store.connectionState = .online
      await store.refresh(using: client, preserveSelection: true)
      store.sessionSnapshotHydrationTask?.cancel()
      store.sessionSnapshotHydrationTask = nil
      #expect(store.sessions.count == fixture.sessions.count)
      #expect(store.projects.count == fixture.projects.count)
    }

    #expect(medianMs <= 160)
  }

  @Test("Performance budget: bookmark toggles stay under 10 ms median with 80 saved bookmarks")
  func bookmarkToggleStaysWithinPerformanceBudget() async throws {
    let store = harness.makeStore()

    for index in 0..<80 {
      harness.container.mainContext.insert(
        SessionBookmark(
          sessionId: "sess-bm-\(index)",
          projectId: "proj-\(index % 6)"
        )
      )
    }
    try harness.container.mainContext.save()
    store.refreshBookmarkedSessionIds()

    let medianMs = await harness.medianRuntimeMs {
      #expect(store.toggleBookmark(sessionId: "sess-bm-40", projectId: "proj-4"))
      #expect(store.isBookmarked(sessionId: "sess-bm-40") == false)
      #expect(store.toggleBookmark(sessionId: "sess-bm-40", projectId: "proj-4"))
      #expect(store.isBookmarked(sessionId: "sess-bm-40"))
    }

    #expect(medianMs <= 10)
  }
}
