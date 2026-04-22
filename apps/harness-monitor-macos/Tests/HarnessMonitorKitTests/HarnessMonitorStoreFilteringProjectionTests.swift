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
          store.visibleSessionIDs
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

    // Repository-backed sessions share one checkout group, so default ordering follows
    // recent activity inside that group.
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

  @Test("Repository-backed sessions collapse into one sidebar checkout group")
  func repositoryBackedSessionsShareOneCheckoutGroup() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.projects = [makeProject(totalSessionCount: 2, activeSessionCount: 2)]

    var first = SessionFixture(
      sessionId: "repo-first",
      context: "Repository lane",
      status: .active,
      leaderId: "leader-first",
      observeId: nil,
      openTaskCount: 1,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 1
    )
    first.lastActivityAt = "2026-03-28T14:05:00Z"

    var second = SessionFixture(
      sessionId: "repo-second",
      context: "Repository lane",
      status: .active,
      leaderId: "leader-second",
      observeId: nil,
      openTaskCount: 1,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 1
    )
    second.lastActivityAt = "2026-03-28T14:20:00Z"

    store.sessions = [
      makeSession(first),
      makeSession(second),
    ]

    guard
      let projectGroup = store.groupedSessions.first,
      let checkoutGroup = projectGroup.checkoutGroups.first
    else {
      Issue.record("Expected one grouped repository checkout")
      return
    }

    #expect(projectGroup.checkoutGroups.count == 1)
    #expect(checkoutGroup.isWorktree == false)
    #expect(checkoutGroup.title == "Repository")
    #expect(checkoutGroup.sessionIDs == ["repo-second", "repo-first"])
  }

  @Test("Linked-worktree sessions reuse one named sidebar checkout group")
  func linkedWorktreeSessionsReuseOneCheckoutGroup() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.projects = [makeProject(totalSessionCount: 2, activeSessionCount: 2)]
    let worktreeRoot = "/Users/example/Projects/harness/.claude/worktrees/feature-branch"

    var first = SessionFixture(
      sessionId: "wt-first",
      context: "Worktree lane",
      status: .active,
      leaderId: "leader-first",
      observeId: nil,
      openTaskCount: 1,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 1
    )
    first.originPath = worktreeRoot
    first.lastActivityAt = "2026-03-28T14:05:00Z"

    var second = SessionFixture(
      sessionId: "wt-second",
      context: "Worktree lane",
      status: .paused,
      leaderId: "leader-second",
      observeId: nil,
      openTaskCount: 0,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 0
    )
    second.originPath = worktreeRoot
    second.lastActivityAt = "2026-03-28T14:20:00Z"

    store.sessions = [
      makeSession(first),
      makeSession(second),
    ]

    guard
      let projectGroup = store.groupedSessions.first,
      let checkoutGroup = projectGroup.checkoutGroups.first
    else {
      Issue.record("Expected one grouped worktree checkout")
      return
    }

    #expect(projectGroup.checkoutGroups.count == 1)
    #expect(checkoutGroup.isWorktree)
    #expect(checkoutGroup.title == "feature-branch")
    #expect(checkoutGroup.sessionIDs == ["wt-second", "wt-first"])
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

}
