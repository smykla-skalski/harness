import Foundation
import SwiftData
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Database management")
struct HarnessMonitorStoreDatabaseTests {
  let container: ModelContainer

  init() throws {
    container = try HarnessMonitorModelContainer.preview()
  }

  private func makeStore() -> HarnessMonitorStore {
    HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      modelContainer: container
    )
  }

  // MARK: - Statistics

  @Test("gatherDatabaseStatistics returns correct counts for empty store")
  func gatherStatisticsEmpty() async {
    let store = makeStore()
    let stats = await store.gatherDatabaseStatistics()

    #expect(stats.sessionCount == 0)
    #expect(stats.projectCount == 0)
    #expect(stats.agentCount == 0)
    #expect(stats.taskCount == 0)
    #expect(stats.signalCount == 0)
    #expect(stats.timelineCount == 0)
    #expect(stats.bookmarkCount == 0)
    #expect(stats.noteCount == 0)
    #expect(stats.searchCount == 0)
    #expect(stats.filterPreferenceCount == 0)
    #expect(stats.totalCacheRecords == 0)
    #expect(stats.totalUserRecords == 0)
  }

  @Test("gatherDatabaseStatistics returns correct counts after populating data")
  func gatherStatisticsPopulated() async {
    let store = makeStore()
    let project = makeProject(totalSessionCount: 2, activeSessionCount: 2)
    let sessionA = makeSession(.init(
      sessionId: "sess-db-a",
      context: "Stats A",
      status: .active,
      leaderId: "leader-a",
      openTaskCount: 0,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 2
    ))
    let sessionB = makeSession(.init(
      sessionId: "sess-db-b",
      context: "Stats B",
      status: .active,
      leaderId: "leader-b",
      openTaskCount: 0,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 2
    ))

    let detailA = makeSessionDetail(
      summary: sessionA,
      workerID: "worker-a",
      workerName: "Worker A"
    )
    let timelineA = makeTimelineEntries(
      sessionID: "sess-db-a",
      agentID: "leader-a",
      summary: "Checkpoint A"
    )

    await store.cacheSessionList([sessionA, sessionB], projects: [project])
    await store.cacheSessionDetail(detailA, timeline: timelineA)

    store.toggleBookmark(sessionId: "sess-db-a", projectId: "project-a")
    store.addNote(
      text: "Test note",
      targetKind: "task",
      targetId: "task-1",
      sessionId: "sess-db-a"
    )
    store.recordSearch("test query")

    let stats = await store.gatherDatabaseStatistics()

    #expect(stats.sessionCount == 2)
    #expect(stats.projectCount == 1)
    #expect(stats.agentCount == 2)
    #expect(stats.timelineCount == 1)
    #expect(stats.bookmarkCount == 1)
    #expect(stats.noteCount == 1)
    #expect(stats.searchCount == 1)
    #expect(stats.totalCacheRecords > 0)
    #expect(stats.totalUserRecords == 3)
  }

  @Test("gatherDatabaseStatistics returns zeroes without persistence")
  func gatherStatisticsNoPersistence() async {
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      persistenceError: "Local persistence is unavailable."
    )
    let stats = await store.gatherDatabaseStatistics()

    #expect(stats.sessionCount == 0)
    #expect(stats.projectCount == 0)
    #expect(stats.bookmarkCount == 0)
    #expect(stats.noteCount == 0)
    #expect(stats.searchCount == 0)
  }

  // MARK: - Clear session cache

  @Test("clearSessionCache removes cached data but preserves user data")
  func clearSessionCachePreservesUserData() async throws {
    let store = makeStore()
    let project = makeProject(totalSessionCount: 1, activeSessionCount: 1)
    let session = makeSession(.init(
      sessionId: "sess-clear-cache",
      context: "Clear cache test",
      status: .active,
      leaderId: "leader-clear",
      openTaskCount: 0,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 2
    ))
    let detail = makeSessionDetail(
      summary: session,
      workerID: "worker-clear",
      workerName: "Worker Clear"
    )

    await store.cacheSessionList([session], projects: [project])
    await store.cacheSessionDetail(detail, timeline: [])
    store.toggleBookmark(sessionId: "sess-clear-cache", projectId: "project-a")
    store.addNote(
      text: "Keep me",
      targetKind: "task",
      targetId: "task-1",
      sessionId: "sess-clear-cache"
    )
    store.recordSearch("preserved query")

    let success = await store.clearSessionCache()
    #expect(success)
    #expect(store.persistedSessionCount == 0)
    #expect(store.lastPersistedSnapshotAt == nil)

    let statsAfter = await store.gatherDatabaseStatistics()
    #expect(statsAfter.sessionCount == 0)
    #expect(statsAfter.projectCount == 0)
    #expect(statsAfter.agentCount == 0)
    #expect(statsAfter.bookmarkCount == 1)
    #expect(statsAfter.noteCount == 1)
    #expect(statsAfter.searchCount == 1)
  }

  @Test("clearSessionCache fails gracefully without persistence")
  func clearSessionCacheNoPersistence() async {
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      persistenceError: "Local persistence is unavailable."
    )

    let success = await store.clearSessionCache()
    #expect(!success)
    #expect(store.lastError != nil)
  }

  // MARK: - Clear user data

  @Test("clearAllUserData removes user data but preserves cache")
  func clearAllUserDataPreservesCache() async throws {
    let store = makeStore()
    let project = makeProject(totalSessionCount: 1, activeSessionCount: 1)
    let session = makeSession(.init(
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
    #expect(store.lastError != nil)
  }

  // MARK: - Clear all data

  @Test("clearAllDatabaseData removes everything")
  func clearAllDatabaseDataRemovesEverything() async throws {
    let store = makeStore()
    let project = makeProject(totalSessionCount: 1, activeSessionCount: 1)
    let session = makeSession(.init(
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
