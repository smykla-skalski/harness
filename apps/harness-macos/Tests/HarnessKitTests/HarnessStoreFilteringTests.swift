import Testing

@testable import HarnessKit

@MainActor
@Suite("Harness store filtering")
struct HarnessStoreFilteringTests {
  @Test(
    "Session focus filter narrows to matching sessions",
    arguments: [
      (SessionFocusFilter.all, ["active", "blocked", "idle"]),
      (.openWork, ["active"]),
      (.blocked, ["blocked"]),
      (.observed, ["active", "blocked"]),
      (.idle, ["idle"]),
    ] as [(SessionFocusFilter, [String])]
  )
  func sessionFocusFilterNarrows(
    filter: SessionFocusFilter,
    expectedIDs: [String]
  ) {
    let store = HarnessStore(daemonController: RecordingDaemonController())
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
    store.sessionFocusFilter = filter

    let resultIDs = store.groupedSessions
      .flatMap(\.sessions)
      .map(\.sessionId)
      .sorted()
    #expect(resultIDs == expectedIDs.sorted())
  }

  @Test(
    "Session status filter includes the correct statuses",
    arguments: [
      (HarnessStore.SessionFilter.active, ["active", "paused"]),
      (.all, ["active", "paused", "ended"]),
      (.ended, ["ended"]),
    ] as [(HarnessStore.SessionFilter, [String])]
  )
  func sessionStatusFilterIncludes(
    filter: HarnessStore.SessionFilter,
    expectedIDs: [String]
  ) {
    let store = HarnessStore(daemonController: RecordingDaemonController())
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
    store.sessionFilter = filter

    let resultIDs = store.groupedSessions
      .flatMap(\.sessions)
      .map(\.sessionId)
      .sorted()
    #expect(resultIDs == expectedIDs.sorted())
  }

  @Test("Filtered session count uses count(where:) correctly")
  func filteredSessionCount() {
    let store = HarnessStore(daemonController: RecordingDaemonController())
    store.projects = [makeProject(totalSessionCount: 3, activeSessionCount: 2)]
    store.sessions = [
      makeSession(
        .init(
          sessionId: "a",
          context: "Active",
          status: .active,
          leaderId: nil,
          observeId: nil,
          openTaskCount: 0,
          inProgressTaskCount: 0,
          blockedTaskCount: 0,
          activeAgentCount: 0
        )
      ),
      makeSession(
        .init(
          sessionId: "b",
          context: "Active",
          status: .active,
          leaderId: nil,
          observeId: nil,
          openTaskCount: 0,
          inProgressTaskCount: 0,
          blockedTaskCount: 0,
          activeAgentCount: 0
        )
      ),
      makeSession(
        .init(
          sessionId: "c",
          context: "Ended",
          status: .ended,
          leaderId: nil,
          observeId: nil,
          openTaskCount: 0,
          inProgressTaskCount: 0,
          blockedTaskCount: 0,
          activeAgentCount: 0
        )
      ),
    ]

    store.sessionFilter = .active
    #expect(store.filteredSessionCount == 2)

    store.sessionFilter = .all
    #expect(store.filteredSessionCount == 3)

    store.sessionFilter = .ended
    #expect(store.filteredSessionCount == 1)
  }

  @Test("Total open work count sums across all sessions")
  func totalOpenWorkCount() {
    let store = HarnessStore(daemonController: RecordingDaemonController())
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
    let store = HarnessStore(daemonController: RecordingDaemonController())
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
    let store = HarnessStore(daemonController: RecordingDaemonController())
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
    let store = HarnessStore(daemonController: RecordingDaemonController())
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
