import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor store filtering")
struct HarnessMonitorStoreFilteringTests {
  private func storeWithFocusFixtures() -> HarnessMonitorStore {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.projects = [makeProject(totalSessionCount: 3, activeSessionCount: 3)]
    store.sessions = [
      makeSession(
        .init(
          sessionId: "active",
          context: "Active work",
          status: .active,
          leaderId: "leader",
          observeId: "observe-active",
          openTaskCount: 2,
          inProgressTaskCount: 1,
          blockedTaskCount: 0,
          activeAgentCount: 1
        )
      ),
      makeSession(
        .init(
          sessionId: "blocked",
          context: "Blocked lane",
          status: .active,
          leaderId: "leader",
          observeId: "observe-blocked",
          openTaskCount: 1,
          inProgressTaskCount: 0,
          blockedTaskCount: 1,
          activeAgentCount: 1
        )
      ),
      makeSession(
        .init(
          sessionId: "idle",
          context: "Idle lane",
          status: .active,
          leaderId: "leader",
          observeId: nil,
          openTaskCount: 0,
          inProgressTaskCount: 0,
          blockedTaskCount: 0,
          activeAgentCount: 0
        )
      ),
    ]
    store.sessionFilter = .active
    return store
  }

  private func filteredIDs(from store: HarnessMonitorStore) -> [String] {
    store.visibleSessionIDs.sorted()
  }

  private func orderedVisibleIDs(from store: HarnessMonitorStore) -> [String] {
    store.visibleSessionIDs
  }

  private func orderedVisibleSessions(from store: HarnessMonitorStore) -> [String] {
    store.visibleSessions.map(\.sessionId)
  }

  @Test("Focus filter .all shows all active sessions")
  func focusFilterAll() {
    let store = storeWithFocusFixtures()
    store.sessionFocusFilter = .all
    #expect(filteredIDs(from: store) == ["active", "blocked", "idle"])
  }

  @Test("Focus filter .openWork shows sessions with open or in-progress tasks")
  func focusFilterOpenWork() {
    let store = storeWithFocusFixtures()
    store.sessionFocusFilter = .openWork
    #expect(filteredIDs(from: store) == ["active", "blocked"])
  }

  @Test("Focus filter .blocked shows sessions with blocked tasks")
  func focusFilterBlocked() {
    let store = storeWithFocusFixtures()
    store.sessionFocusFilter = .blocked
    #expect(filteredIDs(from: store) == ["blocked"])
  }

  @Test("Focus filter .observed shows sessions with an observe ID")
  func focusFilterObserved() {
    let store = storeWithFocusFixtures()
    store.sessionFocusFilter = .observed
    #expect(filteredIDs(from: store) == ["active", "blocked"])
  }

  @Test("Focus filter .idle shows sessions with no active agents or open tasks")
  func focusFilterIdle() {
    let store = storeWithFocusFixtures()
    store.sessionFocusFilter = .idle
    #expect(filteredIDs(from: store) == ["idle"])
  }

  private func storeWithStatusFixtures() -> HarnessMonitorStore {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.projects = [makeProject(totalSessionCount: 3, activeSessionCount: 2)]
    store.sessions = [
      makeSession(
        .init(
          sessionId: "active",
          context: "Active",
          status: .active,
          leaderId: "leader",
          observeId: nil,
          openTaskCount: 1,
          inProgressTaskCount: 0,
          blockedTaskCount: 0,
          activeAgentCount: 1
        )
      ),
      makeSession(
        .init(
          sessionId: "paused",
          context: "Paused",
          status: .paused,
          leaderId: "leader",
          observeId: nil,
          openTaskCount: 0,
          inProgressTaskCount: 0,
          blockedTaskCount: 0,
          activeAgentCount: 0
        )
      ),
      makeSession(
        .init(
          sessionId: "ended",
          context: "Ended",
          status: .ended,
          leaderId: "leader",
          observeId: nil,
          openTaskCount: 0,
          inProgressTaskCount: 0,
          blockedTaskCount: 0,
          activeAgentCount: 0
        )
      ),
    ]
    return store
  }

  @Test("Status filter .active includes active and paused sessions")
  func statusFilterActive() {
    let store = storeWithStatusFixtures()
    store.sessionFilter = .active
    #expect(filteredIDs(from: store) == ["active", "paused"])
  }

  @Test("Status filter .all includes every session")
  func statusFilterAll() {
    let store = storeWithStatusFixtures()
    store.sessionFilter = .all
    #expect(filteredIDs(from: store) == ["active", "ended", "paused"])
  }

  @Test("Status filter .ended includes only ended sessions")
  func statusFilterEnded() {
    let store = storeWithStatusFixtures()
    store.sessionFilter = .ended
    #expect(filteredIDs(from: store) == ["ended"])
  }

  @Test("Filtered session count uses count(where:) correctly")
  func filteredSessionCount() {
    let store = storeWithStatusFixtures()

    store.sessionFilter = .active
    #expect(store.filteredSessionCount == 2)

    store.sessionFilter = .all
    #expect(store.filteredSessionCount == 3)

    store.sessionFilter = .ended
    #expect(store.filteredSessionCount == 1)
  }

  @Test("Visible sessions keep the projected visible order for search-heavy rendering")
  func visibleSessionsMirrorVisibleSessionIDs() {
    let store = storeWithStatusFixtures()

    store.sessionSortOrder = .status
    #expect(orderedVisibleSessions(from: store) == orderedVisibleIDs(from: store))

    store.searchText = "leader"
    #expect(orderedVisibleSessions(from: store) == orderedVisibleIDs(from: store))

    store.sessionFilter = .ended
    #expect(orderedVisibleSessions(from: store) == ["ended"])
    #expect(orderedVisibleSessions(from: store) == orderedVisibleIDs(from: store))
  }

  @Test("Total open work count sums across all sessions")
  func totalOpenWorkCount() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.sessions = [
      makeSession(
        .init(
          sessionId: "a",
          context: "A",
          status: .active,
          leaderId: nil,
          observeId: nil,
          openTaskCount: 3,
          inProgressTaskCount: 0,
          blockedTaskCount: 0,
          activeAgentCount: 0
        )
      ),
      makeSession(
        .init(
          sessionId: "b",
          context: "B",
          status: .active,
          leaderId: nil,
          observeId: nil,
          openTaskCount: 5,
          inProgressTaskCount: 0,
          blockedTaskCount: 0,
          activeAgentCount: 0
        )
      ),
    ]
    #expect(store.totalOpenWorkCount == 8)
  }

  @Test("Total blocked count sums across all sessions")
  func totalBlockedCount() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.sessions = [
      makeSession(
        .init(
          sessionId: "a",
          context: "A",
          status: .active,
          leaderId: nil,
          observeId: nil,
          openTaskCount: 0,
          inProgressTaskCount: 0,
          blockedTaskCount: 2,
          activeAgentCount: 0
        )
      ),
      makeSession(
        .init(
          sessionId: "b",
          context: "B",
          status: .active,
          leaderId: nil,
          observeId: nil,
          openTaskCount: 0,
          inProgressTaskCount: 0,
          blockedTaskCount: 1,
          activeAgentCount: 0
        )
      ),
    ]
    #expect(store.totalBlockedCount == 3)
  }

  @Test("Selected session summary resolves from session list")
  func selectedSessionSummary() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let session = makeSession(
      .init(
        sessionId: "target",
        context: "Target session",
        status: .active,
        leaderId: nil,
        observeId: nil,
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 0
      )
    )
    store.sessions = [session]
    store.selectedSessionID = "target"

    #expect(store.selectedSessionSummary?.sessionId == "target")
    #expect(store.selectedSessionSummary?.context == "Target session")
  }

  @Test("Selected session summary returns nil when no session selected")
  func selectedSessionSummaryNil() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.sessions = [
      makeSession(
        .init(
          sessionId: "a",
          context: "A",
          status: .active,
          leaderId: nil,
          observeId: nil,
          openTaskCount: 0,
          inProgressTaskCount: 0,
          blockedTaskCount: 0,
          activeAgentCount: 0
        )
      )
    ]
    #expect(store.selectedSessionSummary == nil)
  }

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
      }
    )

    #expect(sidebarShellInvalidated == false)
    #expect(store.sessionIndex.debugCatalogRebuildCount == initialCatalogRebuilds)
    #expect(store.sessionIndex.debugProjectionRebuildCount == initialProjectionRebuilds + 1)
  }

  @Test("Projection-only changes do not rebuild the session catalog")
  func projectionOnlyChangesDoNotRebuildTheSessionCatalog() {
    let store = storeWithStatusFixtures()
    let initialCatalogRebuilds = store.sessionIndex.debugCatalogRebuildCount
    let initialProjectionRebuilds = store.sessionIndex.debugProjectionRebuildCount

    store.searchText = "active"

    #expect(store.sessionIndex.debugCatalogRebuildCount == initialCatalogRebuilds)
    #expect(store.sessionIndex.debugProjectionRebuildCount == initialProjectionRebuilds + 1)
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

    #expect(orderedVisibleIDs(from: store) == ["bravo", "zeta", "alpha"])

    let initialCatalogRebuilds = store.sessionIndex.debugCatalogRebuildCount
    let initialProjectionRebuilds = store.sessionIndex.debugProjectionRebuildCount

    store.sessionSortOrder = .name

    #expect(orderedVisibleIDs(from: store) == ["alpha", "bravo", "zeta"])
    #expect(store.sessionIndex.debugCatalogRebuildCount == initialCatalogRebuilds)
    #expect(store.sessionIndex.debugProjectionRebuildCount == initialProjectionRebuilds + 1)

    let projectionAfterNameSort = store.sessionIndex.debugProjectionRebuildCount

    store.sessionSortOrder = .status

    #expect(orderedVisibleIDs(from: store) == ["bravo", "alpha", "zeta"])
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
}
