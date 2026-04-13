import Foundation
import SwiftData
import Testing

@testable import HarnessMonitorKit

private enum CacheWriteFailure: Error {
  case saveFailed
}


@MainActor
extension HarnessMonitorStoreDatabaseTests {
  @Test("cacheSessionList removes orphaned cached projects and sessions")
  func cacheSessionListRemovesOrphanedCachedProjectsAndSessions() async throws {
    let store = makeStore()
    let projectA = makeProject(totalSessionCount: 1, activeSessionCount: 1)
    let projectB = ProjectSummary(
      projectId: "project-b",
      name: "kuma",
      projectDir: "/Users/example/Projects/kuma",
      contextRoot: "/Users/example/Library/Application Support/harness/projects/project-b",
      activeSessionCount: 1,
      totalSessionCount: 1
    )
    let sessionA = makeSession(
      .init(
        sessionId: "sess-keep",
        context: "Keep me",
        status: .active,
        leaderId: "leader-keep",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      )
    )
    let sessionB = makeSession(
      .init(
        sessionId: "sess-drop",
        context: "Drop me",
        status: .active,
        projectName: "kuma",
        projectId: "project-b",
        leaderId: "leader-drop",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      )
    )
    let detailB = makeSessionDetail(
      summary: sessionB,
      workerID: "worker-drop",
      workerName: "Worker Drop"
    )
    let timelineB = makeTimelineEntries(
      sessionID: sessionB.sessionId,
      agentID: "leader-drop",
      summary: "Drop me"
    )

    await store.cacheSessionList([sessionA, sessionB], projects: [projectA, projectB])
    await store.cacheSessionDetail(detailB, timeline: timelineB)

    await store.cacheSessionList([sessionA], projects: [projectA])

    let statsAfter = await store.gatherDatabaseStatistics()
    #expect(statsAfter.sessionCount == 1)
    #expect(statsAfter.projectCount == 1)
    #expect(statsAfter.agentCount == 0)
    #expect(statsAfter.timelineCount == 0)
    if case .some = await store.loadCachedSessionDetail(sessionID: sessionB.sessionId) {
      Issue.record("expected dropped session detail to be removed from cache")
    }
    let cachedList = try #require(await store.loadCachedSessionList())
    #expect(cachedList.sessions.map(\.sessionId) == [sessionA.sessionId])
    #expect(cachedList.projects.map(\.projectId) == [projectA.projectId])
    #expect(store.persistedSessionCount == 1)
  }

  @Test("clearSessionCache fails gracefully without persistence")
  func clearSessionCacheNoPersistence() async {
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      persistenceError: "Local persistence is unavailable."
    )

    let success = await store.clearSessionCache()
    #expect(!success)
    #expect(store.currentFailureFeedbackMessage != nil)
  }

  // MARK: - Clear user data

  @Test("clearAllUserData removes user data but preserves cache")
  func clearAllUserDataPreservesCache() async throws {
    let store = makeStore()
    let project = makeProject(totalSessionCount: 1, activeSessionCount: 1)
    let session = makeSession(
      .init(
        sessionId: "sess-clear-user",
        context: "Clear user test",
        status: .active,
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))

    await store.cacheSessionList([session], projects: [project])
    store.toggleBookmark(sessionId: "sess-clear-user", projectId: "project-a")
    store.addNote(
      text: "Remove me",
      targetKind: "task",
      targetId: "task-1",
      sessionId: "sess-clear-user"
    )
    store.recordSearch("doomed query")
    store.sessionFilter = .ended
    store.saveFilterPreference(for: "project-a")

    let success = store.clearAllUserData()
    #expect(success)
    #expect(store.bookmarkedSessionIds.isEmpty)

    let statsAfter = await store.gatherDatabaseStatistics()
    #expect(statsAfter.sessionCount == 1)
    #expect(statsAfter.projectCount == 1)
    #expect(statsAfter.bookmarkCount == 0)
    #expect(statsAfter.noteCount == 0)
    #expect(statsAfter.searchCount == 0)
    #expect(statsAfter.filterPreferenceCount == 0)
  }

  @Test("clearAllUserData fails gracefully without persistence")
  func clearAllUserDataNoPersistence() {
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      persistenceError: "Local persistence is unavailable."
    )

    let success = store.clearAllUserData()
    #expect(!success)
    #expect(store.currentFailureFeedbackMessage != nil)
  }

  // MARK: - Clear all data

  @Test("clearAllDatabaseData removes everything")
  func clearAllDatabaseDataRemovesEverything() async throws {
    let store = makeStore()
    let project = makeProject(totalSessionCount: 1, activeSessionCount: 1)
    let session = makeSession(
      .init(
        sessionId: "sess-clear-all",
        context: "Clear all test",
        status: .active,
        leaderId: "leader-all",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 2
      ))
    let detail = makeSessionDetail(
      summary: session,
      workerID: "worker-all",
      workerName: "Worker All"
    )

    await store.cacheSessionList([session], projects: [project])
    await store.cacheSessionDetail(detail, timeline: [])
    store.toggleBookmark(sessionId: "sess-clear-all", projectId: "project-a")
    store.addNote(
      text: "Gone",
      targetKind: "task",
      targetId: "task-1",
      sessionId: "sess-clear-all"
    )
    store.recordSearch("gone query")

    let success = await store.clearAllDatabaseData()
    #expect(success)

    let statsAfter = await store.gatherDatabaseStatistics()
    #expect(statsAfter.sessionCount == 0)
    #expect(statsAfter.projectCount == 0)
    #expect(statsAfter.agentCount == 0)
    #expect(statsAfter.bookmarkCount == 0)
    #expect(statsAfter.noteCount == 0)
    #expect(statsAfter.searchCount == 0)
    #expect(statsAfter.totalCacheRecords == 0)
    #expect(statsAfter.totalUserRecords == 0)
  }

  // MARK: - File size helper

  @Test("swiftDataStoreSize returns zero for missing file")
  func fileSizeReturnZeroForMissingFile() {
    let url = URL(fileURLWithPath: "/tmp/nonexistent-harness-test-\(UUID().uuidString).store")
    let size = HarnessMonitorStore.swiftDataStoreSize(at: url)
    #expect(size == 0)
  }

  // MARK: - DatabaseStatistics formatting

  @Test("DatabaseStatistics formats sizes and dates")
  func statisticsFormatting() {
    let stats = DatabaseStatistics(
      sessionCount: 10,
      projectCount: 2,
      agentCount: 20,
      taskCount: 5,
      signalCount: 3,
      timelineCount: 50,
      observerCount: 1,
      activityCount: 15,
      bookmarkCount: 3,
      noteCount: 2,
      searchCount: 5,
      filterPreferenceCount: 1,
      appCacheSizeBytes: 1_048_576,
      daemonDatabaseSizeBytes: 2_097_152,
      lastCachedAt: nil,
      appCacheStorePath: "/tmp/test.store",
      daemonDatabasePath: "/tmp/harness.db"
    )

    #expect(!stats.appCacheSizeFormatted.isEmpty)
    #expect(!stats.daemonDatabaseSizeFormatted.isEmpty)
    #expect(stats.lastCachedFormatted == "Never")
    #expect(stats.totalCacheRecords == 106)
    #expect(stats.totalUserRecords == 11)
  }

  @Test("DatabaseStatistics formats relative date when lastCachedAt is set")
  func statisticsFormatsRelativeDate() {
    let stats = DatabaseStatistics(
      sessionCount: 0,
      projectCount: 0,
      agentCount: 0,
      taskCount: 0,
      signalCount: 0,
      timelineCount: 0,
      observerCount: 0,
      activityCount: 0,
      bookmarkCount: 0,
      noteCount: 0,
      searchCount: 0,
      filterPreferenceCount: 0,
      appCacheSizeBytes: 0,
      daemonDatabaseSizeBytes: 0,
      lastCachedAt: .now,
      appCacheStorePath: "",
      daemonDatabasePath: ""
    )

    #expect(stats.lastCachedFormatted != "Never")
  }
}
