import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor store duplicate session filtering")
struct HarnessMonitorStoreFilteringDuplicateTests {
  @Test("Duplicate session ids collapse before catalog dictionaries are built")
  func duplicateSessionIDsCollapseBeforeCatalogDictionaries() async {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.projects = [makeProject(totalSessionCount: 2, activeSessionCount: 2)]
    let duplicateSessionID = "a1d147c4-8016-4687-a7a8-07b0c3f0c8f7"
    let otherSessionID = "dedb0c88-2bb9-44b4-8cb5-995c585c4453"

    var olderDuplicate = SessionFixture(
      sessionId: duplicateSessionID,
      title: "Older duplicate",
      context: "Duplicate lane",
      status: .active,
      leaderId: "leader-dup",
      observeId: nil,
      openTaskCount: 1,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 1
    )
    olderDuplicate.lastActivityAt = "2026-03-28T14:05:00Z"

    var other = SessionFixture(
      sessionId: otherSessionID,
      title: "Other session",
      context: "Other lane",
      status: .active,
      leaderId: "leader-other",
      observeId: nil,
      openTaskCount: 2,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 1
    )
    other.lastActivityAt = "2026-03-28T14:10:00Z"

    var newerDuplicate = SessionFixture(
      sessionId: duplicateSessionID,
      title: "Newer duplicate",
      context: "Duplicate lane",
      status: .active,
      leaderId: "leader-dup",
      observeId: nil,
      openTaskCount: 3,
      inProgressTaskCount: 0,
      blockedTaskCount: 1,
      activeAgentCount: 1
    )
    newerDuplicate.lastActivityAt = "2026-03-28T14:25:00Z"

    store.sessions = [
      makeSession(olderDuplicate),
      makeSession(other),
      makeSession(newerDuplicate),
    ]
    store.sessionFilter = .all
    await store.waitForSessionIndexIdle()

    #expect(
      store.sessionIndex.catalog.sessions.map(\.sessionId)
        == [otherSessionID, duplicateSessionID]
    )
    #expect(store.sessionIndex.catalog.sessionIDs == [duplicateSessionID, otherSessionID])
    #expect(
      store.sessionIndex.catalog.sessionSummary(for: duplicateSessionID)?.displayTitle
        == "Newer duplicate"
    )
    #expect(store.sessionIndex.catalog.totalSessionCount == 2)
    #expect(store.sessionIndex.catalog.totalOpenWorkCount == 5)
    #expect(store.sessionIndex.catalog.totalBlockedCount == 1)
    #expect(
      HarnessMonitorStoreFilteringTestSupport.orderedVisibleIDs(from: store)
        == [duplicateSessionID, otherSessionID]
    )
  }
}
