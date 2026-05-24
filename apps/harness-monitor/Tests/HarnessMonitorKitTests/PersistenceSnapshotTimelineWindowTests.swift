import SwiftData
import Testing

@testable import HarnessMonitorKit

@MainActor
extension PersistenceSnapshotIntegrationTests {
  @Test("cacheSessionDetail preserves existing timeline window metadata when caller omits it")
  func cacheSessionDetailPreservesExistingTimelineWindowMetadataWhenCallerOmitsIt() async throws {
    let store = harness.makeStore()
    let session = makeSession(
      .init(
        sessionId: "sess-window-preserve",
        context: "Window preserve test",
        status: .active,
        leaderId: "leader-window-preserve",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 2
      ))

    let detail = makeSessionDetail(
      summary: session,
      workerID: "worker-window-preserve",
      workerName: "Window Preserve Worker"
    )
    let timeline = makeTimelineEntries(
      sessionID: session.sessionId,
      agentID: "leader-window-preserve",
      summary: "Window preserve checkpoint"
    )
    let timelineWindow = TimelineWindowResponse(
      revision: 11,
      totalCount: 64,
      windowStart: 0,
      windowEnd: timeline.count,
      hasOlder: true,
      hasNewer: false,
      oldestCursor: timeline.last.map {
        TimelineCursor(recordedAt: $0.recordedAt, entryId: $0.entryId)
      },
      newestCursor: timeline.first.map {
        TimelineCursor(recordedAt: $0.recordedAt, entryId: $0.entryId)
      },
      entries: nil,
      unchanged: false
    )

    await store.cacheSessionDetail(
      detail,
      timeline: timeline,
      timelineWindow: timelineWindow
    )

    let updatedSummary = SessionSummary(
      projectId: detail.session.projectId,
      projectName: detail.session.projectName,
      projectDir: detail.session.projectDir,
      contextRoot: detail.session.contextRoot,
      sessionId: detail.session.sessionId,
      worktreePath: detail.session.worktreePath,
      sharedPath: detail.session.sharedPath,
      originPath: detail.session.originPath,
      branchRef: detail.session.branchRef,
      title: detail.session.title,
      context: "Updated preserve test",
      status: detail.session.status,
      createdAt: detail.session.createdAt,
      updatedAt: "2026-04-14T12:34:56Z",
      lastActivityAt: "2026-04-14T12:34:56Z",
      leaderId: detail.session.leaderId,
      observeId: detail.session.observeId,
      pendingLeaderTransfer: detail.session.pendingLeaderTransfer,
      metrics: detail.session.metrics
    )
    let updatedDetail = makeSessionDetail(
      summary: updatedSummary,
      workerID: "worker-window-preserve",
      workerName: "Window Preserve Worker"
    )

    await store.cacheSessionDetail(updatedDetail, timeline: timeline)

    let cached = try #require(await store.loadCachedSessionDetail(sessionID: session.sessionId))
    #expect(cached.detail.session.context == "Updated preserve test")
    #expect(cached.timelineWindow?.revision == timelineWindow.revision)
    #expect(cached.timelineWindow?.totalCount == timelineWindow.totalCount)
  }

  @Test("cacheSessionDetail clears stale timeline window when timeline becomes empty")
  func cacheSessionDetailClearsStaleTimelineWindowWhenTimelineBecomesEmpty() async throws {
    let store = harness.makeStore()
    let session = makeSession(
      .init(
        sessionId: "sess-stale-window",
        context: "Stale window test",
        status: .active,
        leaderId: "leader-stale",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))
    let detail = makeSessionDetail(
      summary: session,
      workerID: "worker-stale",
      workerName: "Stale Worker"
    )
    let timeline = makeTimelineEntries(
      sessionID: session.sessionId,
      agentID: "leader-stale",
      summary: "Stale checkpoint"
    )
    let timelineWindow = TimelineWindowResponse(
      revision: 3,
      totalCount: 3,
      windowStart: 0,
      windowEnd: timeline.count,
      hasOlder: false,
      hasNewer: false,
      oldestCursor: nil,
      newestCursor: nil,
      entries: nil,
      unchanged: false
    )

    await store.cacheSessionDetail(
      detail,
      timeline: timeline,
      timelineWindow: timelineWindow
    )

    // A later write with an empty timeline must not leave the old window metadata behind,
    // otherwise the UI renders "Showing 0-0 of 3" forever.
    await store.cacheSessionDetail(detail, timeline: [])

    let cached = try #require(await store.loadCachedSessionDetail(sessionID: session.sessionId))
    #expect(cached.timeline.isEmpty)
    #expect(
      cached.timelineWindow?.totalCount ?? 0 == 0,
      "stale totalCount must be cleared when the cached timeline is emptied"
    )
  }

  @Test("preview containers keep in-memory cache isolated")
  func previewContainersKeepInMemoryCacheIsolated() async throws {
    let firstContainer = try HarnessMonitorModelContainer.preview()
    let firstStore = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      modelContainer: firstContainer
    )
    let session = makeSession(
      .init(
        sessionId: "sess-preview-isolation",
        context: "Preview isolation",
        status: .active,
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))
    let detail = makeSessionDetail(
      summary: session,
      workerID: "worker-preview-isolation",
      workerName: "Preview Worker"
    )

    await firstStore.cacheSessionDetail(detail, timeline: [])

    let secondContainer = try HarnessMonitorModelContainer.preview()
    let secondStore = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      modelContainer: secondContainer
    )

    #expect(await secondStore.loadCachedSessionDetail(sessionID: session.sessionId) == nil)
  }

  @Test("cacheSessionDetail updates existing session in place")
  func cacheSessionDetailUpdatesInPlace() async throws {
    let store = harness.makeStore()
    let session = makeSession(
      .init(
        sessionId: "sess-update",
        context: "Original",
        status: .active,
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))

    let detail = makeSessionDetail(
      summary: session,
      workerID: "w-1",
      workerName: "Worker"
    )
    await store.cacheSessionDetail(detail, timeline: [])

    let updated = makeSession(
      .init(
        sessionId: "sess-update",
        context: "Updated",
        status: .active,
        openTaskCount: 3,
        inProgressTaskCount: 1,
        blockedTaskCount: 0,
        activeAgentCount: 2
      ))
    let updatedDetail = makeSessionDetail(
      summary: updated,
      workerID: "w-2",
      workerName: "New Worker"
    )
    await store.cacheSessionDetail(updatedDetail, timeline: [])

    let descriptor = FetchDescriptor<CachedSession>()
    let all = try harness.container.mainContext.fetch(descriptor)
    #expect(all.count == 1)

    let cached = await store.loadCachedSessionDetail(sessionID: "sess-update")
    #expect(cached?.detail.session.context == "Updated")
    #expect(cached?.detail.agents.count == 2)
  }
}
