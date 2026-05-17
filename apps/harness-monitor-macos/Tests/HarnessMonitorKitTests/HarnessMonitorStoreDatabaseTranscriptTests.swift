import Foundation
import SwiftData
import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreDatabaseTests {
  @Test("cacheSessionDetail round-trips transcript rows through the side table")
  func cacheSessionDetailRoundTripsTranscriptRows() async throws {
    let store = makeStore()
    let summary = makeSession(
      .init(
        sessionId: "sess-transcript-roundtrip",
        context: "Transcript roundtrip lane",
        status: .active,
        leaderId: "leader-transcript-roundtrip",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 2
      ))
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-transcript-roundtrip",
      workerName: "Worker Transcript Roundtrip"
    )
    let timeline = makeTimelineEntries(
      sessionID: summary.sessionId,
      agentID: "leader-transcript-roundtrip",
      summary: "Timeline row"
    )
    let transcript = [
      TimelineEntry(
        entryId: "acp-transcript-roundtrip",
        recordedAt: "2026-04-28T00:00:20Z",
        kind: "assistant_message",
        sessionId: summary.sessionId,
        agentId: "worker-transcript-roundtrip",
        taskId: nil,
        summary: "Dedicated transcript row",
        payload: .object(["runtime": .string("acp")])
      )
    ]

    await store.cacheSessionDetail(detail, timeline: timeline, transcript: transcript)

    let cached = try #require(await store.loadCachedSessionDetail(sessionID: summary.sessionId))
    #expect(cached.timeline.map(\.summary) == ["Timeline row"])
    #expect(cached.transcript?.map(\.summary) == ["Dedicated transcript row"])
    let stats = await store.gatherDatabaseStatistics()
    #expect(stats.transcriptCount == 1)
  }

  @Test("Stopping streams cancels pending cache writes before they persist")
  func stoppingStreamsCancelsPendingCacheWrites() async throws {
    let delayedCacheService = SessionCacheService(
      modelContainer: container,
      beforeSave: {
        try await Task.sleep(for: .seconds(5))
      }
    )
    let store = makeStore(cacheService: delayedCacheService)
    let summary = makeSession(
      .init(
        sessionId: "sess-pending-cache-write",
        context: "Pending cache write",
        status: .active,
        leaderId: "leader-pending-cache-write",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))

    store.applySessionSummaryUpdate(summary)
    #expect(store.pendingCacheWriteTask != nil)

    store.stopAllStreams()
    try? await Task.sleep(for: .milliseconds(50))

    #expect(store.pendingCacheWriteTask == nil)
    #expect(store.persistedSessionCount == 0)
    if case .some = await store.loadCachedSessionList() {
      Issue.record("Expected cancelled cache write task to leave the cache unchanged")
    }
  }

  // MARK: - Clear session cache

  @Test("clearSessionCache removes cached data but preserves user data")
  func clearSessionCachePreservesUserData() async throws {
    let store = makeStore()
    let project = makeProject(totalSessionCount: 1, activeSessionCount: 1)
    let session = makeSession(
      .init(
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
    await store.toggleBookmark(sessionId: "sess-clear-cache", projectId: "project-a")
    await store.addNote(
      text: "Keep me",
      targetKind: "task",
      targetId: "task-1",
      sessionId: "sess-clear-cache"
    )
    await store.recordSearch("preserved query")

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
}
