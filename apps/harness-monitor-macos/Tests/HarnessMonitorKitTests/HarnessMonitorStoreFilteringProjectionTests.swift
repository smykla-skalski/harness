import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor store filtering projection")
struct HarnessMonitorStoreProjectionTests {
  @Test("Sidebar UI list-facing state ignores footer-only metric churn")
  func sidebarUIListFacingStateIgnoresFooterMetricChurn() async {
    let store = await makeBootstrappedStore()

    let didChange = await didInvalidate(
      {
        (
          store.sidebarUI.selectedSessionID,
          store.sidebarUI.bookmarkedSessionIds
        )
      },
      after: {
        var metrics = store.connectionMetrics
        metrics.messagesReceived += 1
        metrics.messagesPerSecond = 8
        store.connectionMetrics = metrics
      }
    )

    #expect(didChange == false)
  }

  @Test("Sidebar bookmarks invalidate the shell while search stays in projection state")
  func sidebarShellAndProjectionObservationBoundaries() async {
    let store = await makeBootstrappedStore()

    let bookmarkInvalidated = await didInvalidate(
      { store.sidebarUI.bookmarkedSessionIds },
      after: {
        store.bookmarkedSessionIds = ["bookmark-observed"]
      }
    )
    #expect(bookmarkInvalidated)

    let initialCatalogRebuilds = store.sessionIndex.debugCatalogRebuildCount
    let initialProjectionRebuilds = store.sessionIndex.debugProjectionRebuildCount
    let sidebarShellInvalidated = await didInvalidate(
      {
        (
          store.sidebarUI.selectedSessionID,
          store.sidebarUI.bookmarkedSessionIds
        )
      },
      after: {
        store.searchText = "preview"
        store.flushPendingSearchRebuild()
      }
    )

    #expect(sidebarShellInvalidated == false)
    #expect(store.sessionIndex.debugCatalogRebuildCount == initialCatalogRebuilds)
    #expect(store.sessionIndex.debugProjectionRebuildCount == initialProjectionRebuilds + 1)
  }

  @Test("Projection-only changes do not rebuild the session catalog")
  func projectionOnlyChangesDoNotRebuildTheSessionCatalog() {
    let store = HarnessMonitorStoreFilteringTestSupport.storeWithStatusFixtures()
    let initialCatalogRebuilds = store.sessionIndex.debugCatalogRebuildCount
    let initialProjectionRebuilds = store.sessionIndex.debugProjectionRebuildCount

    store.searchText = "active"
    store.flushPendingSearchRebuild()

    #expect(store.sessionIndex.debugCatalogRebuildCount == initialCatalogRebuilds)
    #expect(store.sessionIndex.debugProjectionRebuildCount == initialProjectionRebuilds + 1)
  }

  @Test("Search projection skips publishing projection slice changes")
  func searchProjectionSkipsPublishingProjectionSliceChanges() async {
    let store = HarnessMonitorStoreFilteringTestSupport.storeWithStatusFixtures()
    let initialGroupedSessions = store.sessionIndex.projection.groupedSessions
    let initialFilteredSessionCount = store.sessionIndex.projection.filteredSessionCount
    let initialTotalSessionCount = store.sessionIndex.projection.totalSessionCount
    let initialEmptyState = store.sessionIndex.projection.emptyState

    let projectionInvalidated = await didInvalidate(
      {
        (
          store.sessionIndex.projection.groupedSessions,
          store.sessionIndex.projection.filteredSessionCount,
          store.sessionIndex.projection.totalSessionCount,
          store.sessionIndex.projection.emptyState
        )
      },
      after: {
        store.searchText = "active"
        store.flushPendingSearchRebuild()
      }
    )

    #expect(projectionInvalidated == false)
    #expect(store.sessionIndex.projection.groupedSessions == initialGroupedSessions)
    #expect(store.sessionIndex.projection.filteredSessionCount == initialFilteredSessionCount)
    #expect(store.sessionIndex.projection.totalSessionCount == initialTotalSessionCount)
    #expect(store.sessionIndex.projection.emptyState == initialEmptyState)
    #expect(store.visibleSessionIDs == ["active"])
    #expect(store.groupedSessions.flatMap(\.sessionIDs) == ["active"])
  }

  @Test("Search list-facing state ignores count-only churn")
  func searchListFacingStateIgnoresCountOnlyChurn() async {
    let store = HarnessMonitorStoreFilteringTestSupport.storeWithStatusFixtures()
    store.searchText = "active"
    store.flushPendingSearchRebuild()

    let hiddenSession = makeSession(
      .init(
        sessionId: "hidden-ended",
        context: "Hidden ended lane",
        status: .ended,
        leaderId: "leader-hidden",
        observeId: nil,
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 0
      )
    )

    let didChange = await didInvalidate(
      {
        (
          store.sessionIndex.searchResults.isSearchActive,
          store.sessionIndex.searchResults.emptyState,
          store.sessionIndex.searchResults.visibleSessionIDs,
          store.visibleSessions.map(\.sessionId)
        )
      },
      after: {
        var sessions = store.sessions
        sessions.append(hiddenSession)
        store.sessions = sessions
      }
    )

    #expect(didChange == false)
    #expect(store.sessionIndex.searchResults.totalSessionCount == 4)
    #expect(store.visibleSessionIDs == ["active"])
  }

  @Test("Sort order changes update projection without rebuilding the catalog")
  func sortOrderChangesUpdateProjectionWithoutCatalogRebuild() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.projects = [makeProject(totalSessionCount: 3, activeSessionCount: 2)]

    var alpha = SessionFixture(
      sessionId: "alpha",
      title: "Alpha",
      context: "Alpha lane",
      status: .paused,
      leaderId: "leader-alpha",
      observeId: nil,
      openTaskCount: 0,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 0
    )
    alpha.lastActivityAt = "2026-03-28T14:05:00Z"

    var zeta = SessionFixture(
      sessionId: "zeta",
      title: "Zeta",
      context: "Zeta lane",
      status: .ended,
      leaderId: "leader-zeta",
      observeId: nil,
      openTaskCount: 0,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 0
    )
    zeta.lastActivityAt = "2026-03-28T14:10:00Z"

    var bravo = SessionFixture(
      sessionId: "bravo",
      title: "Bravo",
      context: "Bravo lane",
      status: .active,
      leaderId: "leader-bravo",
      observeId: nil,
      openTaskCount: 1,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 1
    )
    bravo.lastActivityAt = "2026-03-28T14:15:00Z"

    store.sessions = [
      makeSession(alpha),
      makeSession(zeta),
      makeSession(bravo),
    ]
    store.sessionFilter = .all

    #expect(
      HarnessMonitorStoreFilteringTestSupport.orderedVisibleIDs(from: store)
        == ["bravo", "zeta", "alpha"]
    )

    let initialCatalogRebuilds = store.sessionIndex.debugCatalogRebuildCount
    let initialProjectionRebuilds = store.sessionIndex.debugProjectionRebuildCount

    store.sessionSortOrder = .name

    #expect(
      HarnessMonitorStoreFilteringTestSupport.orderedVisibleIDs(from: store)
        == ["alpha", "bravo", "zeta"]
    )
    #expect(store.sessionIndex.debugCatalogRebuildCount == initialCatalogRebuilds)
    #expect(store.sessionIndex.debugProjectionRebuildCount == initialProjectionRebuilds + 1)

    let projectionAfterNameSort = store.sessionIndex.debugProjectionRebuildCount

    store.sessionSortOrder = .status

    #expect(
      HarnessMonitorStoreFilteringTestSupport.orderedVisibleIDs(from: store)
        == ["bravo", "alpha", "zeta"]
    )
    #expect(store.sessionIndex.debugCatalogRebuildCount == initialCatalogRebuilds)
    #expect(store.sessionIndex.debugProjectionRebuildCount == projectionAfterNameSort + 1)
  }

  @Test("Session summary patch updates projection without a full catalog rebuild")
  func sessionSummaryPatchUpdatesProjectionWithoutCatalogRebuild() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.projects = [makeProject(totalSessionCount: 2, activeSessionCount: 2)]

    var older = SessionFixture(
      sessionId: "older",
      context: "Older lane",
      status: .active,
      leaderId: "leader-older",
      observeId: nil,
      openTaskCount: 1,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 1
    )
    older.lastActivityAt = "2026-03-28T14:05:00Z"

    var updated = SessionFixture(
      sessionId: "updated",
      context: "Updated lane",
      status: .active,
      leaderId: "leader-updated",
      observeId: "observe-updated",
      openTaskCount: 1,
      inProgressTaskCount: 1,
      blockedTaskCount: 0,
      activeAgentCount: 2
    )
    updated.lastActivityAt = "2026-03-28T14:10:00Z"

    store.sessions = [
      makeSession(older),
      makeSession(updated),
    ]

    let initialCatalogRebuilds = store.sessionIndex.debugCatalogRebuildCount
    let initialProjectionRebuilds = store.sessionIndex.debugProjectionRebuildCount

    updated.context = "Updated lane with refreshed detail"
    updated.openTaskCount = 4
    updated.lastActivityAt = "2026-03-28T14:30:00Z"

    let didChange = store.sessionIndex.applySessionSummary(makeSession(updated))

    #expect(didChange)
    #expect(store.sessionIndex.debugCatalogRebuildCount == initialCatalogRebuilds)
    #expect(store.sessionIndex.debugProjectionRebuildCount == initialProjectionRebuilds + 1)
    #expect(store.sessionIndex.sessionSummary(for: "updated")?.context == updated.context)
    #expect(store.totalOpenWorkCount == 5)
    #expect(store.recentSessions.first?.sessionId == "updated")
  }

  @Test("Projection summary patch refreshes search ordering without a full catalog rebuild")
  func projectionSummaryPatchRefreshesSearchOrderingWithoutCatalogRebuild() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.projects = [makeProject(totalSessionCount: 2, activeSessionCount: 2)]

    var first = SessionFixture(
      sessionId: "first",
      title: "First",
      context: "Shared lane",
      status: .active,
      leaderId: "leader-first",
      observeId: nil,
      openTaskCount: 1,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 1
    )
    first.lastActivityAt = "2026-03-28T14:30:00Z"

    var second = SessionFixture(
      sessionId: "second",
      title: "Second",
      context: "Shared lane",
      status: .active,
      leaderId: "leader-second",
      observeId: nil,
      openTaskCount: 1,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 1
    )
    second.lastActivityAt = "2026-03-28T14:10:00Z"

    store.sessions = [
      makeSession(first),
      makeSession(second),
    ]
    store.searchText = "shared"
    store.flushPendingSearchRebuild()

    #expect(store.visibleSessionIDs == ["first", "second"])

    let initialCatalogRebuilds = store.sessionIndex.debugCatalogRebuildCount
    let initialProjectionRebuilds = store.sessionIndex.debugProjectionRebuildCount
    guard let baseline = store.sessionIndex.sessionSummary(for: "second") else {
      Issue.record("Missing second fixture session")
      return
    }

    let updated = makeUpdatedSession(
      baseline,
      context: baseline.context,
      updatedAt: "2026-03-28T14:45:00Z",
      agentCount: baseline.metrics.activeAgentCount
    )

    let didChange = store.sessionIndex.applySessionSummary(updated)

    #expect(didChange)
    #expect(store.sessionIndex.debugCatalogRebuildCount == initialCatalogRebuilds)
    #expect(store.sessionIndex.debugProjectionRebuildCount == initialProjectionRebuilds + 1)
    #expect(store.visibleSessionIDs == ["second", "first"])
  }

  @Test("Summary-only updates skip projection rebuilds")
  func summaryOnlyUpdatesSkipProjectionRebuilds() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.projects = [makeProject(totalSessionCount: 1, activeSessionCount: 1)]
    let session = makeSession(
      .init(
        sessionId: "summary-only",
        context: "Summary only lane",
        status: .active,
        leaderId: "leader-a",
        observeId: "observe-summary-only",
        openTaskCount: 2,
        inProgressTaskCount: 1,
        blockedTaskCount: 0,
        activeAgentCount: 1
      )
    )
    store.sessions = [session]

    let initialCatalogRebuilds = store.sessionIndex.debugCatalogRebuildCount
    let initialProjectionRebuilds = store.sessionIndex.debugProjectionRebuildCount

    let updated = SessionSummary(
      projectId: session.projectId,
      projectName: session.projectName,
      projectDir: session.projectDir,
      contextRoot: session.contextRoot,
      checkoutId: session.checkoutId,
      checkoutRoot: session.checkoutRoot,
      isWorktree: session.isWorktree,
      worktreeName: session.worktreeName,
      sessionId: session.sessionId,
      title: session.title,
      context: session.context,
      status: session.status,
      createdAt: session.createdAt,
      updatedAt: session.updatedAt,
      lastActivityAt: "2026-04-09T11:39:00Z",
      leaderId: session.leaderId,
      observeId: session.observeId,
      pendingLeaderTransfer: PendingLeaderTransfer(
        requestedBy: "tester",
        currentLeaderId: session.leaderId ?? "leader-a",
        newLeaderId: "leader-b",
        requestedAt: "2026-04-09T11:40:00Z",
        reason: "handoff"
      ),
      metrics: session.metrics
    )

    let didChange = store.sessionIndex.applySessionSummary(updated)

    #expect(didChange)
    #expect(store.sessionIndex.debugCatalogRebuildCount == initialCatalogRebuilds)
    #expect(store.sessionIndex.debugProjectionRebuildCount == initialProjectionRebuilds)
    #expect(store.sessionIndex.sessionSummary(for: session.sessionId) == updated)
    #expect(store.groupedSessions.first?.sessionIDs.first == updated.sessionId)
    #expect(store.sessionIndex.catalog.sessionSummary(for: session.sessionId) == updated)
    #expect(store.recentSessions.first == updated)
  }

  @Test("Projection-affecting summary updates only resync the toolbar when no session is selected")
  func projectionSummaryUpdateOnlyResyncsToolbarWhenSelectionIsEmpty() {
    let store = HarnessMonitorStoreFilteringTestSupport.storeWithStatusFixtures()
    store.debugResetUISyncCounts()

    guard let active = store.sessionIndex.sessionSummary(for: "active") else {
      Issue.record("Missing active fixture session")
      return
    }

    let updated = SessionSummary(
      projectId: active.projectId,
      projectName: active.projectName,
      projectDir: active.projectDir,
      contextRoot: active.contextRoot,
      checkoutId: active.checkoutId,
      checkoutRoot: active.checkoutRoot,
      isWorktree: active.isWorktree,
      worktreeName: active.worktreeName,
      sessionId: active.sessionId,
      title: active.title,
      context: active.context,
      status: active.status,
      createdAt: active.createdAt,
      updatedAt: active.updatedAt,
      lastActivityAt: active.lastActivityAt,
      leaderId: active.leaderId,
      observeId: active.observeId,
      pendingLeaderTransfer: active.pendingLeaderTransfer,
      metrics: SessionMetrics(
        agentCount: active.metrics.agentCount,
        activeAgentCount: active.metrics.activeAgentCount,
        openTaskCount: 4,
        inProgressTaskCount: active.metrics.inProgressTaskCount,
        blockedTaskCount: active.metrics.blockedTaskCount,
        completedTaskCount: active.metrics.completedTaskCount
      )
    )

    let didChange = store.sessionIndex.applySessionSummary(updated)

    #expect(didChange)
    #expect(store.debugUISyncCount(for: .contentToolbar) == 1)
    #expect(store.debugUISyncCount(for: .contentShell) == 0)
    #expect(store.debugUISyncCount(for: .contentChrome) == 0)
    #expect(store.debugUISyncCount(for: .contentSession) == 0)
    #expect(store.debugUISyncCount(for: .contentSessionDetail) == 0)
    #expect(store.debugUISyncCount(for: .contentDashboard) == 0)
    #expect(store.debugUISyncCount(for: .inspector) == 0)
  }

  @Test("Summary-only updates skip all content resync when the selected session is elsewhere")
  func summaryOnlyUpdateSkipsContentResyncForUnselectedSession() {
    let store = HarnessMonitorStoreFilteringTestSupport.storeWithStatusFixtures()
    store.debugResetUISyncCounts()

    guard let paused = store.sessionIndex.sessionSummary(for: "paused") else {
      Issue.record("Missing paused fixture session")
      return
    }

    let updated = SessionSummary(
      projectId: paused.projectId,
      projectName: paused.projectName,
      projectDir: paused.projectDir,
      contextRoot: paused.contextRoot,
      checkoutId: paused.checkoutId,
      checkoutRoot: paused.checkoutRoot,
      isWorktree: paused.isWorktree,
      worktreeName: paused.worktreeName,
      sessionId: paused.sessionId,
      title: paused.title,
      context: paused.context,
      status: paused.status,
      createdAt: paused.createdAt,
      updatedAt: paused.updatedAt,
      lastActivityAt: paused.lastActivityAt,
      leaderId: paused.leaderId,
      observeId: paused.observeId,
      pendingLeaderTransfer: PendingLeaderTransfer(
        requestedBy: "tester",
        currentLeaderId: paused.leaderId ?? "leader",
        newLeaderId: "leader-next",
        requestedAt: "2026-04-11T10:00:00Z",
        reason: "handoff"
      ),
      metrics: paused.metrics
    )

    let didChange = store.sessionIndex.applySessionSummary(updated)

    #expect(didChange)
    #expect(store.debugUISyncCount(for: .contentToolbar) == 0)
    #expect(store.debugUISyncCount(for: .contentShell) == 0)
    #expect(store.debugUISyncCount(for: .contentChrome) == 0)
    #expect(store.debugUISyncCount(for: .contentSession) == 0)
    #expect(store.debugUISyncCount(for: .contentSessionDetail) == 0)
    #expect(store.debugUISyncCount(for: .contentDashboard) == 0)
    #expect(store.debugUISyncCount(for: .inspector) == 0)
  }

  @Test("Recent sessions stay sorted by activity outside the visible filter")
  func recentSessionsStaySortedByActivityOutsideVisibleFilter() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.projects = [makeProject(totalSessionCount: 3, activeSessionCount: 2)]

    var active = SessionFixture(
      sessionId: "active",
      context: "Active lane",
      status: .active,
      leaderId: "leader-active",
      observeId: nil,
      openTaskCount: 1,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 1
    )
    active.lastActivityAt = "2026-03-28T14:05:00Z"

    var paused = SessionFixture(
      sessionId: "paused",
      context: "Paused lane",
      status: .paused,
      leaderId: "leader-paused",
      observeId: nil,
      openTaskCount: 0,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 0
    )
    paused.lastActivityAt = "2026-03-28T14:15:00Z"

    var ended = SessionFixture(
      sessionId: "ended",
      context: "Ended lane",
      status: .ended,
      leaderId: "leader-ended",
      observeId: nil,
      openTaskCount: 0,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 0
    )
    ended.lastActivityAt = "2026-03-28T14:25:00Z"

    store.sessions = [
      makeSession(active),
      makeSession(paused),
      makeSession(ended),
    ]

    store.sessionFilter = .ended

    #expect(store.visibleSessionIDs == ["ended"])
    #expect(store.recentSessions.map(\.sessionId) == ["ended", "paused", "active"])
  }

  @Test("Rapid search updates coalesce to a single projection rebuild")
  func rapidSearchUpdatesCoalesceToSingleProjectionRebuild() async {
    let store = HarnessMonitorStoreFilteringTestSupport.storeWithStatusFixtures()
    let initialProjectionRebuilds = store.sessionIndex.debugProjectionRebuildCount

    store.searchText = "a"
    store.searchText = "ac"
    store.searchText = "act"
    store.searchText = "acti"
    store.searchText = "activ"
    store.searchText = "active"

    #expect(store.sessionIndex.debugProjectionRebuildCount == initialProjectionRebuilds)

    try? await Task.sleep(nanoseconds: 300_000_000)

    #expect(store.sessionIndex.debugProjectionRebuildCount == initialProjectionRebuilds + 1)
    #expect(store.visibleSessionIDs == ["active"])
  }

  @Test("Filter change cancels pending search rebuild debounce")
  func filterChangeCancelsPendingSearchRebuild() async {
    let store = HarnessMonitorStoreFilteringTestSupport.storeWithStatusFixtures()
    let initialProjectionRebuilds = store.sessionIndex.debugProjectionRebuildCount

    store.searchText = "active"
    #expect(store.sessionIndex.debugProjectionRebuildCount == initialProjectionRebuilds)

    store.sessionFilter = .active
    #expect(store.sessionIndex.debugProjectionRebuildCount == initialProjectionRebuilds + 1)

    try? await Task.sleep(nanoseconds: 300_000_000)

    #expect(store.sessionIndex.debugProjectionRebuildCount == initialProjectionRebuilds + 1)
  }

  @Test("Flush runs pending search rebuild synchronously")
  func flushRunsPendingSearchRebuildSynchronously() {
    let store = HarnessMonitorStoreFilteringTestSupport.storeWithStatusFixtures()
    let initialProjectionRebuilds = store.sessionIndex.debugProjectionRebuildCount

    store.searchText = "active"
    #expect(store.sessionIndex.debugProjectionRebuildCount == initialProjectionRebuilds)

    store.flushPendingSearchRebuild()

    #expect(store.sessionIndex.debugProjectionRebuildCount == initialProjectionRebuilds + 1)
    #expect(store.visibleSessionIDs == ["active"])
  }

  @Test("Flush is a no-op when no search rebuild is pending")
  func flushIsNoOpWhenNoPendingSearchRebuild() {
    let store = HarnessMonitorStoreFilteringTestSupport.storeWithStatusFixtures()
    let initialProjectionRebuilds = store.sessionIndex.debugProjectionRebuildCount

    store.flushPendingSearchRebuild()

    #expect(store.sessionIndex.debugProjectionRebuildCount == initialProjectionRebuilds)
  }
}
