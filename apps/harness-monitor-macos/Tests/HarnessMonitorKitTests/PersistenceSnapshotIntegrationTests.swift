import SwiftData
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Persistence snapshot integration")
struct PersistenceSnapshotIntegrationTests {
  let harness: PersistenceIntegrationTestHarness

  init() throws {
    harness = try PersistenceIntegrationTestHarness()
  }

  @Test("cacheSessionList writes projects and sessions")
  func cacheSessionListWritesThenReads() async throws {
    let store = harness.makeStore()
    let project = makeProject(totalSessionCount: 1, activeSessionCount: 1)
    let session = makeSession(
      .init(
        sessionId: "sess-1",
        context: "Test session",
        status: .active,
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))

    await store.cacheSessionList([session], projects: [project])

    let cached = await store.loadCachedSessionList()
    #expect(cached != nil)
    #expect(cached?.sessions.count == 1)
    #expect(cached?.sessions.first?.sessionId == "sess-1")
    #expect(cached?.projects.count == 1)
    #expect(cached?.projects.first?.projectId == project.projectId)
  }

  @Test("cacheSessionDetail stores full detail and timeline")
  func cacheSessionDetailWritesThenReads() async throws {
    let store = harness.makeStore()
    let session = makeSession(
      .init(
        sessionId: "sess-detail",
        context: "Detail test",
        status: .active,
        leaderId: "leader-1",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 2
      ))

    let detail = makeSessionDetail(
      summary: session,
      workerID: "worker-1",
      workerName: "Codex Worker"
    )
    let timeline = makeTimelineEntries(
      sessionID: "sess-detail",
      agentID: "leader-1",
      summary: "Test checkpoint"
    )

    await store.cacheSessionDetail(detail, timeline: timeline)

    let cached = await store.loadCachedSessionDetail(sessionID: "sess-detail")
    #expect(cached != nil)
    #expect(cached?.detail.session.sessionId == "sess-detail")
    #expect(cached?.detail.agents.count == 2)
    #expect(cached?.timeline.count == 1)
    #expect(cached?.timeline.first?.summary == "Test checkpoint")
  }

  @Test("cacheSessionDetail stores timeline window metadata")
  func cacheSessionDetailStoresTimelineWindowMetadata() async throws {
    let store = harness.makeStore()
    let session = makeSession(
      .init(
        sessionId: "sess-window-detail",
        context: "Window detail test",
        status: .active,
        leaderId: "leader-window",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 2
      ))

    let detail = makeSessionDetail(
      summary: session,
      workerID: "worker-window",
      workerName: "Window Worker"
    )
    let timeline = makeTimelineEntries(
      sessionID: session.sessionId,
      agentID: "leader-window",
      summary: "Window checkpoint"
    )
    let timelineWindow = TimelineWindowResponse(
      revision: 9,
      totalCount: 42,
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

    let cachedModels = try harness.container.mainContext.fetch(FetchDescriptor<CachedSession>())
    #expect(cachedModels.count == 1)
    #expect(cachedModels.first(where: { $0.sessionId == "sess-window-detail" })?.timelineWindowData != nil)

    let cached = try #require(await store.loadCachedSessionDetail(sessionID: "sess-window-detail"))
    #expect(cached.timelineWindow?.revision == 9)
    #expect(cached.timelineWindow?.totalCount == 42)
    #expect(cached.timelineWindow?.windowEnd == timeline.count)
  }

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
      checkoutId: detail.session.checkoutId,
      checkoutRoot: detail.session.checkoutRoot,
      isWorktree: detail.session.isWorktree,
      worktreeName: detail.session.worktreeName,
      sessionId: detail.session.sessionId,
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

  @Test("loadCachedSessionDetail restores canonical agent and task ordering")
  func loadCachedSessionDetailRestoresCanonicalOrdering() async throws {
    let store = harness.makeStore()
    let summary = makeSession(
      .init(
        sessionId: "sess-ordering",
        context: "Ordering",
        status: .active,
        leaderId: "leader-1",
        openTaskCount: 2,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 3
      ))

    let detail = SessionDetail(
      session: summary,
      agents: makeOrderingTestAgents(),
      tasks: makeOrderingTestTasks(),
      signals: [],
      observer: nil,
      agentActivity: []
    )

    await store.cacheSessionDetail(detail, timeline: [])
    let cached = try #require(await store.loadCachedSessionDetail(sessionID: "sess-ordering"))

    #expect(cached.detail.agents.map(\.agentId) == ["leader-1", "reviewer-1", "worker-1"])
    #expect(cached.detail.tasks.map(\.taskId) == ["task-b", "task-a", "task-c"])
  }

  private func makeOrderingTestAgents() -> [AgentRegistration] {
    let caps = PreviewFixtures.agents[0].runtimeCapabilities
    let stamp = "2026-04-12T10:05:00Z"
    return [
      AgentRegistration(
        agentId: "worker-1",
        name: "Worker",
        runtime: "codex",
        role: .worker,
        capabilities: [],
        joinedAt: "2026-04-12T10:01:00Z",
        updatedAt: stamp,
        status: .active,
        agentSessionId: "worker-1-session",
        lastActivityAt: stamp,
        currentTaskId: nil,
        runtimeCapabilities: caps,
        persona: nil
      ),
      AgentRegistration(
        agentId: "leader-1",
        name: "Leader",
        runtime: "claude",
        role: .leader,
        capabilities: [],
        joinedAt: "2026-04-12T10:00:00Z",
        updatedAt: stamp,
        status: .active,
        agentSessionId: "leader-1-session",
        lastActivityAt: stamp,
        currentTaskId: nil,
        runtimeCapabilities: caps,
        persona: nil
      ),
      AgentRegistration(
        agentId: "reviewer-1",
        name: "Reviewer",
        runtime: "codex",
        role: .reviewer,
        capabilities: [],
        joinedAt: "2026-04-12T10:02:00Z",
        updatedAt: stamp,
        status: .active,
        agentSessionId: "reviewer-1-session",
        lastActivityAt: stamp,
        currentTaskId: nil,
        runtimeCapabilities: caps,
        persona: nil
      ),
    ]
  }

  private func makeOrderingTestTasks() -> [WorkItem] {
    [
      WorkItem(
        taskId: "task-a",
        title: "A",
        context: nil,
        severity: .critical,
        status: .open,
        assignedTo: nil,
        createdAt: "2026-04-12T09:00:00Z",
        updatedAt: "2026-04-12T10:00:00Z",
        createdBy: nil,
        notes: [],
        suggestedFix: nil,
        source: .manual,
        blockedReason: nil,
        completedAt: nil,
        checkpointSummary: nil
      ),
      WorkItem(
        taskId: "task-b",
        title: "B",
        context: nil,
        severity: .critical,
        status: .open,
        assignedTo: nil,
        createdAt: "2026-04-12T09:05:00Z",
        updatedAt: "2026-04-12T10:00:00Z",
        createdBy: nil,
        notes: [],
        suggestedFix: nil,
        source: .manual,
        blockedReason: nil,
        completedAt: nil,
        checkpointSummary: nil
      ),
      WorkItem(
        taskId: "task-c",
        title: "C",
        context: nil,
        severity: .high,
        status: .open,
        assignedTo: nil,
        createdAt: "2026-04-12T09:10:00Z",
        updatedAt: "2026-04-12T10:01:00Z",
        createdBy: nil,
        notes: [],
        suggestedFix: nil,
        source: .manual,
        blockedReason: nil,
        completedAt: nil,
        checkpointSummary: nil
      ),
    ]
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
