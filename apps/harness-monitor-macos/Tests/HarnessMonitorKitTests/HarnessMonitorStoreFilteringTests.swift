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
    store.groupedSessions.flatMap(\.sessions).map(\.sessionId).sorted()
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
      ),
    ]
    #expect(store.selectedSessionSummary == nil)
  }
}
