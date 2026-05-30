import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor store filtering basics")
struct HarnessMonitorStoreFilteringBasicsTests {
  @Test("Focus filter .all shows all active sessions")
  func focusFilterAll() async {
    let store = HarnessMonitorStoreFilteringTestSupport.storeWithFocusFixtures()
    await store.waitForSessionIndexIdle()
    store.sessionFocusFilter = .all
    await store.waitForSessionIndexIdle()
    #expect(
      HarnessMonitorStoreFilteringTestSupport.filteredIDs(from: store)
        == ["active", "blocked", "idle"]
    )
  }

  @Test("Focus filter .openWork shows sessions with open or in-progress tasks")
  func focusFilterOpenWork() async {
    let store = HarnessMonitorStoreFilteringTestSupport.storeWithFocusFixtures()
    await store.waitForSessionIndexIdle()
    store.sessionFocusFilter = .openWork
    await store.waitForSessionIndexIdle()
    #expect(
      HarnessMonitorStoreFilteringTestSupport.filteredIDs(from: store)
        == ["active", "blocked"]
    )
  }

  @Test("Focus filter .blocked shows sessions with blocked tasks")
  func focusFilterBlocked() async {
    let store = HarnessMonitorStoreFilteringTestSupport.storeWithFocusFixtures()
    await store.waitForSessionIndexIdle()
    store.sessionFocusFilter = .blocked
    await store.waitForSessionIndexIdle()
    #expect(HarnessMonitorStoreFilteringTestSupport.filteredIDs(from: store) == ["blocked"])
  }

  @Test("Focus filter .observed shows sessions with an observe ID")
  func focusFilterObserved() async {
    let store = HarnessMonitorStoreFilteringTestSupport.storeWithFocusFixtures()
    await store.waitForSessionIndexIdle()
    store.sessionFocusFilter = .observed
    await store.waitForSessionIndexIdle()
    #expect(
      HarnessMonitorStoreFilteringTestSupport.filteredIDs(from: store)
        == ["active", "blocked"]
    )
  }

  @Test("Focus filter .idle shows sessions with no active agents or open tasks")
  func focusFilterIdle() async {
    let store = HarnessMonitorStoreFilteringTestSupport.storeWithFocusFixtures()
    await store.waitForSessionIndexIdle()
    store.sessionFocusFilter = .idle
    await store.waitForSessionIndexIdle()
    #expect(HarnessMonitorStoreFilteringTestSupport.filteredIDs(from: store) == ["idle"])
  }

  @Test("Status filter .active includes active and paused sessions")
  func statusFilterActive() async {
    let store = HarnessMonitorStoreFilteringTestSupport.storeWithStatusFixtures()
    await store.waitForSessionIndexIdle()
    store.sessionFilter = .active
    await store.waitForSessionIndexIdle()
    #expect(
      HarnessMonitorStoreFilteringTestSupport.filteredIDs(from: store)
        == ["active", "paused"]
    )
  }

  @Test("Status filter .all includes every session")
  func statusFilterAll() async {
    let store = HarnessMonitorStoreFilteringTestSupport.storeWithStatusFixtures()
    await store.waitForSessionIndexIdle()
    store.sessionFilter = .all
    await store.waitForSessionIndexIdle()
    #expect(
      HarnessMonitorStoreFilteringTestSupport.filteredIDs(from: store)
        == ["active", "ended", "paused"]
    )
  }

  @Test("Status filter .ended includes only ended sessions")
  func statusFilterEnded() async {
    let store = HarnessMonitorStoreFilteringTestSupport.storeWithStatusFixtures()
    await store.waitForSessionIndexIdle()
    store.sessionFilter = .ended
    await store.waitForSessionIndexIdle()
    #expect(HarnessMonitorStoreFilteringTestSupport.filteredIDs(from: store) == ["ended"])
  }

  @Test("Filtered session count uses count(where:) correctly")
  func filteredSessionCount() async {
    let store = HarnessMonitorStoreFilteringTestSupport.storeWithStatusFixtures()
    await store.waitForSessionIndexIdle()

    store.sessionFilter = .active
    await store.waitForSessionIndexIdle()
    #expect(store.filteredSessionCount == 2)

    store.sessionFilter = .all
    await store.waitForSessionIndexIdle()
    #expect(store.filteredSessionCount == 3)

    store.sessionFilter = .ended
    await store.waitForSessionIndexIdle()
    #expect(store.filteredSessionCount == 1)
  }

  @Test("Visible sessions keep the projected visible order for search-heavy rendering")
  func visibleSessionsMirrorVisibleSessionIDs() async {
    let store = HarnessMonitorStoreFilteringTestSupport.storeWithStatusFixtures()
    await store.waitForSessionIndexIdle()

    store.sessionSortOrder = .status
    await store.waitForSessionIndexIdle()
    #expect(
      HarnessMonitorStoreFilteringTestSupport.orderedVisibleSessions(from: store)
        == HarnessMonitorStoreFilteringTestSupport.orderedVisibleIDs(from: store)
    )

    store.searchText = "leader"
    store.flushPendingSearchRebuild()
    await store.waitForSessionIndexIdle()
    #expect(
      HarnessMonitorStoreFilteringTestSupport.orderedVisibleSessions(from: store)
        == HarnessMonitorStoreFilteringTestSupport.orderedVisibleIDs(from: store)
    )

    store.sessionFilter = .ended
    await store.waitForSessionIndexIdle()
    #expect(
      HarnessMonitorStoreFilteringTestSupport.orderedVisibleSessions(from: store)
        == ["ended"]
    )
    #expect(
      HarnessMonitorStoreFilteringTestSupport.orderedVisibleSessions(from: store)
        == HarnessMonitorStoreFilteringTestSupport.orderedVisibleIDs(from: store)
    )
  }

  @Test("Search active state follows committed projection rebuilds")
  func searchActiveStateFollowsProjectionRebuilds() async {
    let store = HarnessMonitorStoreFilteringTestSupport.storeWithStatusFixtures()
    await store.waitForSessionIndexIdle()

    #expect(store.sessionIndex.searchResults.isSearchActive == false)

    store.searchText = "leader"
    #expect(store.sessionIndex.searchResults.isSearchActive == false)

    store.flushPendingSearchRebuild()
    await store.waitForSessionIndexIdle()
    #expect(store.sessionIndex.searchResults.isSearchActive == true)

    store.searchText = ""
    #expect(store.sessionIndex.searchResults.isSearchActive == true)

    store.flushPendingSearchRebuild()
    await store.waitForSessionIndexIdle()
    #expect(store.sessionIndex.searchResults.isSearchActive == false)
  }

  @Test("Search result observation ignores project-header-only updates")
  func searchResultObservationIgnoresProjectHeaderOnlyUpdates() async {
    let store = HarnessMonitorStoreFilteringTestSupport.storeWithStatusFixtures()
    await store.waitForSessionIndexIdle()
    store.searchText = "leader"
    store.flushPendingSearchRebuild()
    await store.waitForSessionIndexIdle()

    let renamedProject = ProjectSummary(
      projectId: "project-a",
      name: "harness-renamed",
      projectDir: "/Users/example/Projects/harness",
      contextRoot: "/Users/example/Library/Application Support/harness/projects/project-a",
      activeSessionCount: 2,
      totalSessionCount: 3
    )

    let didChange = await didInvalidate(
      { store.visibleSessions.map(\.sessionId) },
      after: {
        store.projects = [renamedProject]
      }
    )
    await store.waitForSessionIndexIdle()

    #expect(didChange == false)
    #expect(store.groupedSessions.first?.project.name == "harness-renamed")
    #expect(
      HarnessMonitorStoreFilteringTestSupport.orderedVisibleSessions(from: store)
        == HarnessMonitorStoreFilteringTestSupport.orderedVisibleIDs(from: store)
    )
  }

  @Test("Total open work count sums across all sessions")
  func totalOpenWorkCount() async {
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
    await store.waitForSessionIndexIdle()
    #expect(store.totalOpenWorkCount == 8)
  }

  @Test("Total blocked count sums across all sessions")
  func totalBlockedCount() async {
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
    await store.waitForSessionIndexIdle()
    #expect(store.totalBlockedCount == 3)
  }

  @Test("Selected session summary resolves from session list")
  func selectedSessionSummary() async {
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
    await store.waitForSessionIndexIdle()

    #expect(store.selectedSessionSummary?.sessionId == "target")
    #expect(store.selectedSessionSummary?.context == "Target session")
  }

  @Test("Selected session summary returns nil when no session selected")
  func selectedSessionSummaryNil() async {
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
    await store.waitForSessionIndexIdle()
    #expect(store.selectedSessionSummary == nil)
  }
}
