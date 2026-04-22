import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor store filtering projection patches")
struct HarnessMonitorStoreProjectionPatchTests {
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
