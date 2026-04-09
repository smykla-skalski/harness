@testable import HarnessMonitorKit

@MainActor
enum HarnessMonitorStoreFilteringTestSupport {
  static func storeWithFocusFixtures() -> HarnessMonitorStore {
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

  static func storeWithStatusFixtures() -> HarnessMonitorStore {
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

  static func filteredIDs(from store: HarnessMonitorStore) -> [String] {
    store.visibleSessionIDs.sorted()
  }

  static func orderedVisibleIDs(from store: HarnessMonitorStore) -> [String] {
    store.visibleSessionIDs
  }

  static func orderedVisibleSessions(from store: HarnessMonitorStore) -> [String] {
    store.visibleSessions.map(\.sessionId)
  }
}
