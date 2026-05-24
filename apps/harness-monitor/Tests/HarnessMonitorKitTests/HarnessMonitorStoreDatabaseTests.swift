import Foundation
import SwiftData
import Testing

@testable import HarnessMonitorKit

private enum CacheWriteFailure: Error {
  case saveFailed
}

@MainActor
@Suite("Database management")
struct HarnessMonitorStoreDatabaseTests {
  let container: ModelContainer

  init() throws {
    container = try HarnessMonitorModelContainer.preview()
  }

  func makeStore(
    cacheService: SessionCacheService? = nil
  ) -> HarnessMonitorStore {
    HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      modelContainer: container,
      cacheService: cacheService
    )
  }

  // MARK: - Statistics

  @Test("Current schema alias stays aligned with the latest cache schema")
  func currentSchemaAliasTracksLatestVersion() {
    #expect(
      HarnessMonitorCurrentSchema.versionIdentifier == HarnessMonitorSchemaV22.versionIdentifier)
    #expect(HarnessMonitorCurrentSchema.versionString == "22.0.0")
  }

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
    #expect(stats.transcriptCount == 0)
    #expect(stats.bookmarkCount == 0)
    #expect(stats.noteCount == 0)
    #expect(stats.searchCount == 0)
    #expect(stats.filterPreferenceCount == 0)
    #expect(stats.notificationCount == 0)
    #expect(stats.totalCacheRecords == 0)
    #expect(stats.totalUserRecords == 0)
  }

  @Test("gatherDatabaseStatistics returns correct counts after populating data")
  func gatherStatisticsPopulated() async {
    let store = makeStore()
    let project = makeProject(totalSessionCount: 2, activeSessionCount: 2)
    let sessionA = makeSession(
      .init(
        sessionId: "sess-db-a",
        context: "Stats A",
        status: .active,
        leaderId: "leader-a",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 2
      ))
    let sessionB = makeSession(
      .init(
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
    let transcriptA = [
      TimelineEntry(
        entryId: "transcript-db-a",
        recordedAt: "2026-04-28T00:00:20Z",
        kind: "assistant_message",
        sessionId: sessionA.sessionId,
        agentId: "worker-a",
        taskId: nil,
        summary: "Dedicated transcript row",
        payload: .object(["runtime": .string("acp")])
      )
    ]

    await store.cacheSessionList([sessionA, sessionB], projects: [project])
    await store.cacheSessionDetail(detailA, timeline: timelineA, transcript: transcriptA)

    await store.toggleBookmark(sessionId: "sess-db-a", projectId: "project-a")
    await store.addNote(
      text: "Test note",
      targetKind: "task",
      targetId: "task-1",
      sessionId: "sess-db-a"
    )
    await store.recordSearch("test query")

    let stats = await store.gatherDatabaseStatistics()

    #expect(stats.sessionCount == 2)
    #expect(stats.projectCount == 1)
    #expect(stats.agentCount == 2)
    #expect(stats.timelineCount == 1)
    #expect(stats.transcriptCount == 1)
    #expect(stats.bookmarkCount == 1)
    #expect(stats.noteCount == 1)
    #expect(stats.searchCount == 1)
    #expect(stats.notificationCount == 0)
    #expect(stats.totalCacheRecords > 0)
    #expect(stats.totalUserRecords == 3)
  }

  @Test("cacheSessionDetail round-trips transcript provenance")
  func cacheSessionDetailRoundTripsTranscriptProvenance() async throws {
    let store = makeStore()
    let summary = makeSession(
      .init(
        sessionId: "sess-db-transcript-source",
        context: "Transcript source",
        status: .active,
        leaderId: "leader-transcript-source",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-transcript-source",
      workerName: "Worker Transcript Source"
    )
    let transcript = [
      TimelineEntry(
        entryId: "transcript-derived",
        recordedAt: "2026-04-28T00:00:20Z",
        kind: "assistant_text",
        sessionId: summary.sessionId,
        agentId: "worker-transcript-source",
        taskId: nil,
        summary: "Derived transcript row",
        payload: .object(["runtime": .string("gemini")])
      )
    ]

    await store.cacheSessionDetail(
      detail,
      timeline: transcript,
      transcript: transcript,
      transcriptSource: .derived,
      timelineWindow: TimelineWindowResponse.fallbackMetadata(for: transcript)
    )

    let cached = try #require(await store.loadCachedSessionDetail(sessionID: summary.sessionId))
    #expect(cached.transcript?.map(\.summary) == ["Derived transcript row"])
    #expect(cached.transcriptSource == .derived)
  }

  @Test("cacheSessionDetail keeps the newest timeline and transcript rows")
  func cacheSessionDetailKeepsNewestTimelineAndTranscriptRows() async throws {
    let store = makeStore()
    let summary = makeSession(
      .init(
        sessionId: "sess-db-transcript-cap",
        context: "Transcript cap",
        status: .active,
        leaderId: "leader-transcript-cap",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-transcript-cap",
      workerName: "Worker Transcript Cap"
    )
    let timeline = makeDescendingEntries(
      prefix: "timeline",
      count: 350,
      sessionID: summary.sessionId,
      agentID: "worker-transcript-cap",
      kind: "task_started"
    )
    let transcript = makeDescendingEntries(
      prefix: "transcript",
      count: 350,
      sessionID: summary.sessionId,
      agentID: "worker-transcript-cap",
      kind: "assistant_message"
    )

    await store.cacheSessionDetail(detail, timeline: timeline, transcript: transcript)

    let cached = try #require(await store.loadCachedSessionDetail(sessionID: summary.sessionId))
    #expect(cached.timeline.count == SessionCacheService.maxCachedTimelineEntries)
    #expect(cached.transcript?.count == SessionCacheService.maxCachedTranscriptEntries)
    #expect(cached.timeline.first?.entryId == "timeline-349")
    #expect(cached.timeline.last?.entryId == "timeline-50")
    #expect(cached.transcript?.first?.entryId == "transcript-349")
    #expect(cached.transcript?.last?.entryId == "transcript-50")
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
    #expect(stats.transcriptCount == 0)
    #expect(stats.bookmarkCount == 0)
    #expect(stats.noteCount == 0)
    #expect(stats.searchCount == 0)
    #expect(stats.notificationCount == 0)
  }

  // MARK: - Cache write reliability

  @Test("Failed cache writes do not advance persisted metadata")
  func failedCacheWritesDoNotAdvancePersistedMetadata() async throws {
    let failingCacheService = SessionCacheService(
      modelContainer: container,
      saveChanges: { _ in
        throw CacheWriteFailure.saveFailed
      }
    )
    let store = makeStore(cacheService: failingCacheService)
    let summary = makeSession(
      .init(
        sessionId: "sess-save-failure",
        context: "Save failure",
        status: .active,
        leaderId: "leader-save-failure",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-save-failure",
      workerName: "Worker Save Failure"
    )

    await store.cacheSessionDetail(detail, timeline: [])

    #expect(store.persistedSessionCount == 0)
    #expect(store.lastPersistedSnapshotAt == nil)
    if case .some = await store.loadCachedSessionDetail(sessionID: summary.sessionId) {
      Issue.record("Expected failed cache save to leave persisted detail unchanged")
    }
  }
}

private func makeDescendingEntries(
  prefix: String,
  count: Int,
  sessionID: String,
  agentID: String,
  kind: String
) -> [TimelineEntry] {
  stride(from: count - 1, through: 0, by: -1).map { index in
    TimelineEntry(
      entryId: "\(prefix)-\(index)",
      recordedAt: recordedAt(for: index),
      kind: kind,
      sessionId: sessionID,
      agentId: agentID,
      taskId: nil,
      summary: "\(prefix) row \(index)",
      payload: .object([:])
    )
  }
}

private func recordedAt(for index: Int) -> String {
  String(
    format: "2026-04-28T%02d:%02d:%02dZ",
    index / 3600,
    (index / 60) % 60,
    index % 60
  )
}
