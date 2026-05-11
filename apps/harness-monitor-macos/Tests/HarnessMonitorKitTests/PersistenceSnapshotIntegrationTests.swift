import SwiftData
import Testing

@testable import HarnessMonitorKit

// swiftlint:disable file_length
// swiftlint:disable type_body_length
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

  @Test("cacheSessionDetail preserves managed-agent refs for cached agents")
  func cacheSessionDetailPreservesManagedAgentRefs() async throws {
    let store = harness.makeStore()
    let session = makeSession(
      .init(
        sessionId: "sess-managed-agent",
        context: "Managed agent cache test",
        status: .active,
        leaderId: "leader-managed",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 2
      ))
    let capabilities = PreviewFixtures.agents[0].runtimeCapabilities
    let detail = SessionDetail(
      session: session,
      agents: [
        AgentRegistration(
          agentId: "leader-managed",
          name: "Leader Managed",
          runtime: "claude",
          role: .leader,
          capabilities: ["general"],
          joinedAt: session.createdAt,
          updatedAt: session.updatedAt,
          status: .active,
          agentSessionId: "leader-managed-session",
          lastActivityAt: session.lastActivityAt,
          currentTaskId: nil,
          runtimeCapabilities: capabilities,
          persona: nil
        ),
        AgentRegistration(
          agentId: "worker-managed",
          name: "Managed Worker",
          runtime: "gemini",
          role: .worker,
          capabilities: ["general"],
          joinedAt: session.createdAt,
          updatedAt: session.updatedAt,
          status: .active,
          agentSessionId: "worker-managed-session",
          managedAgent: ManagedAgentRef(kind: .acp, id: "managed-acp-worker"),
          lastActivityAt: session.lastActivityAt,
          currentTaskId: nil,
          runtimeCapabilities: capabilities,
          persona: nil
        ),
      ],
      tasks: [],
      signals: [],
      observer: nil,
      agentActivity: []
    )

    await store.cacheSessionDetail(detail, timeline: [])

    let cached = try #require(await store.loadCachedSessionDetail(sessionID: session.sessionId))
    let worker = try #require(cached.detail.agents.first { $0.agentId == "worker-managed" })
    #expect(worker.managedAgent == ManagedAgentRef(kind: .acp, id: "managed-acp-worker"))
  }

  @Test("cacheSessionDetail refresh heals cached agents missing managed-agent refs")
  func cacheSessionDetailRefreshHealsMissingManagedAgentRefs() async throws {
    let store = harness.makeStore()
    let session = makeSession(
      .init(
        sessionId: "sess-managed-heal",
        context: "Managed agent heal test",
        status: .active,
        leaderId: "leader-heal",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))
    let capabilities = PreviewFixtures.agents[0].runtimeCapabilities
    let staleDetail = SessionDetail(
      session: session,
      agents: [
        AgentRegistration(
          agentId: "worker-heal",
          name: "Heal Worker",
          runtime: "gemini",
          role: .worker,
          capabilities: ["general"],
          joinedAt: session.createdAt,
          updatedAt: session.updatedAt,
          status: .active,
          agentSessionId: "worker-heal-session",
          lastActivityAt: session.lastActivityAt,
          currentTaskId: nil,
          runtimeCapabilities: capabilities,
          persona: nil
        )
      ],
      tasks: [],
      signals: [],
      observer: nil,
      agentActivity: []
    )
    let cachedSession = staleDetail.session.toCachedSession()
    cachedSession.agents = staleDetail.agents.map { $0.toCachedAgent() }
    harness.container.mainContext.insert(cachedSession)
    try harness.container.mainContext.save()

    let staleSnapshot = try #require(
      await store.loadCachedSessionDetail(sessionID: session.sessionId)
    )
    #expect(staleSnapshot.detail.agents.first?.managedAgent == nil)

    let healedDetail = SessionDetail(
      session: session,
      agents: [
        AgentRegistration(
          agentId: "worker-heal",
          name: "Heal Worker",
          runtime: "gemini",
          role: .worker,
          capabilities: ["general"],
          joinedAt: session.createdAt,
          updatedAt: session.updatedAt,
          status: .active,
          agentSessionId: "worker-heal-session",
          managedAgent: ManagedAgentRef(kind: .acp, id: "managed-acp-heal"),
          lastActivityAt: session.lastActivityAt,
          currentTaskId: nil,
          runtimeCapabilities: capabilities,
          persona: nil
        )
      ],
      tasks: [],
      signals: [],
      observer: nil,
      agentActivity: []
    )

    await store.cacheSessionDetail(healedDetail, timeline: [])

    let healedSnapshot = try #require(
      await store.loadCachedSessionDetail(sessionID: session.sessionId)
    )
    #expect(
      healedSnapshot.detail.agents.first?.managedAgent
        == ManagedAgentRef(kind: .acp, id: "managed-acp-heal"))
  }

  @Test("cached ACP lifecycle uses the managed-agent ref restored from persistence")
  func cachedAcpLifecycleUsesRestoredManagedAgentRef() async throws {
    let store = harness.makeStore()
    let session = makeSession(
      .init(
        sessionId: "sess-managed-lifecycle",
        context: "Managed agent lifecycle test",
        status: .active,
        leaderId: "leader-lifecycle",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))
    let capabilities = PreviewFixtures.agents[0].runtimeCapabilities
    let detail = SessionDetail(
      session: session,
      agents: [
        AgentRegistration(
          agentId: "worker-lifecycle",
          name: "Lifecycle Worker",
          runtime: "gemini",
          role: .worker,
          capabilities: ["general"],
          joinedAt: session.createdAt,
          updatedAt: session.updatedAt,
          status: .active,
          agentSessionId: "worker-lifecycle-session",
          managedAgent: ManagedAgentRef(kind: .acp, id: "managed-acp-lifecycle"),
          lastActivityAt: session.lastActivityAt,
          currentTaskId: nil,
          runtimeCapabilities: capabilities,
          persona: nil
        )
      ],
      tasks: [],
      signals: [],
      observer: nil,
      agentActivity: []
    )

    await store.cacheSessionDetail(detail, timeline: [])

    let cached = try #require(await store.loadCachedSessionDetail(sessionID: session.sessionId))
    store.selectedSessionID = session.sessionId
    store.isShowingCachedSelectedSession = true

    let lifecycle = store.agentLifecyclePresentation(
      for: try #require(cached.detail.agents.first),
      sessionID: session.sessionId,
      sessionRegistrations: cached.detail.agents,
      tuiStatus: nil
    )

    #expect(lifecycle.label == "Disconnected")
    #expect(lifecycle.visualStatus == .disconnected)
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
    #expect(
      cachedModels.first(where: { $0.sessionId == "sess-window-detail" })?.timelineWindowData != nil
    )

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
// swiftlint:enable type_body_length
