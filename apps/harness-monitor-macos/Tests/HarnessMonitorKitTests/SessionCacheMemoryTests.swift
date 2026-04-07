import Foundation
import SwiftData
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Session cache memory fixes")
struct SessionCacheMemoryTests {
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

  // MARK: - Timeline entry cap

  @Test("syncTimeline caps entries at 300 per session")
  func syncTimelineCapsAt300() async throws {
    let store = makeStore()
    let session = makeSession(.init(
      sessionId: "sess-cap",
      context: "Cap test",
      status: .active,
      leaderId: "leader-cap",
      openTaskCount: 0,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 1
    ))

    let detail = SessionDetail(
      session: session,
      agents: [],
      tasks: [],
      signals: [],
      observer: nil,
      agentActivity: []
    )

    let entries = (0..<500).map { index in
      TimelineEntry(
        entryId: "entry-\(index)",
        recordedAt: String(
          format: "2026-04-01T%02d:%02d:%02dZ",
          index / 3600, (index / 60) % 60, index % 60
        ),
        kind: "task_checkpoint",
        sessionId: "sess-cap",
        agentId: "leader-cap",
        taskId: nil,
        summary: "Entry \(index)",
        payload: .object([:])
      )
    }

    await store.cacheSessionDetail(detail, timeline: entries)

    let descriptor = FetchDescriptor<CachedTimelineEntry>(
      predicate: #Predicate { $0.sessionId == "sess-cap" }
    )
    let stored = try container.mainContext.fetch(descriptor)
    #expect(stored.count == 300)

    let storedIds = Set(stored.map(\.entryId))
    #expect(storedIds.contains("entry-499"))
    #expect(storedIds.contains("entry-200"))
    #expect(!storedIds.contains("entry-0"))
    #expect(!storedIds.contains("entry-199"))
  }

  @Test("syncTimeline trims existing entries beyond cap on update")
  func syncTimelineTrimsOnUpdate() async throws {
    let store = makeStore()
    let session = makeSession(.init(
      sessionId: "sess-trim",
      context: "Trim test",
      status: .active,
      leaderId: "leader-trim",
      openTaskCount: 0,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 1
    ))
    let detail = SessionDetail(
      session: session,
      agents: [],
      tasks: [],
      signals: [],
      observer: nil,
      agentActivity: []
    )

    let initialEntries = (0..<250).map { index in
      TimelineEntry(
        entryId: "old-\(index)",
        recordedAt: "2026-04-01T00:00:\(String(format: "%02d", index % 60))Z",
        kind: "task_checkpoint",
        sessionId: "sess-trim",
        agentId: "leader-trim",
        taskId: nil,
        summary: "Old \(index)",
        payload: .object([:])
      )
    }
    await store.cacheSessionDetail(detail, timeline: initialEntries)

    let updatedEntries = (0..<350).map { index in
      TimelineEntry(
        entryId: "new-\(index)",
        recordedAt: "2026-04-02T00:00:\(String(format: "%02d", index % 60))Z",
        kind: "task_checkpoint",
        sessionId: "sess-trim",
        agentId: "leader-trim",
        taskId: nil,
        summary: "New \(index)",
        payload: .object([:])
      )
    }
    await store.cacheSessionDetail(detail, timeline: updatedEntries)

    let descriptor = FetchDescriptor<CachedTimelineEntry>(
      predicate: #Predicate { $0.sessionId == "sess-trim" }
    )
    let stored = try container.mainContext.fetch(descriptor)
    #expect(stored.count == 300)

    let storedIds = Set(stored.map(\.entryId))
    #expect(!storedIds.contains("old-0"))
    #expect(storedIds.contains("new-349"))
    #expect(storedIds.contains("new-50"))
    #expect(!storedIds.contains("new-49"))
  }

  @Test("syncTimeline keeps all entries when under cap")
  func syncTimelineKeepsAllUnderCap() async throws {
    let store = makeStore()
    let session = makeSession(.init(
      sessionId: "sess-small",
      context: "Small timeline",
      status: .active,
      openTaskCount: 0,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 1
    ))
    let detail = SessionDetail(
      session: session,
      agents: [],
      tasks: [],
      signals: [],
      observer: nil,
      agentActivity: []
    )

    let entries = (0..<50).map { index in
      TimelineEntry(
        entryId: "small-\(index)",
        recordedAt: "2026-04-01T00:00:00Z",
        kind: "task_checkpoint",
        sessionId: "sess-small",
        agentId: nil,
        taskId: nil,
        summary: "Small \(index)",
        payload: .object([:])
      )
    }
    await store.cacheSessionDetail(detail, timeline: entries)

    let descriptor = FetchDescriptor<CachedTimelineEntry>(
      predicate: #Predicate { $0.sessionId == "sess-small" }
    )
    let stored = try container.mainContext.fetch(descriptor)
    #expect(stored.count == 50)
  }

  // MARK: - hasDetailSnapshot via fetchCount

  @Test("Hydration queue detects detail via timeline entries, not relationships")
  func hydrationQueueDetectsDetailViaTimelineEntries() async throws {
    let store = makeStore()
    let project = makeProject(totalSessionCount: 1, activeSessionCount: 1)
    let session = makeSession(.init(
      sessionId: "sess-detect",
      context: "Detection test",
      status: .active,
      leaderId: "leader-detect",
      openTaskCount: 0,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 1
    ))

    await store.cacheSessionList([session], projects: [project])

    let needsHydration = await store.persistedSnapshotHydrationQueue(
      for: [session]
    )
    #expect(!needsHydration.isEmpty)

    let detail = makeSessionDetail(
      summary: session,
      workerID: "worker-detect",
      workerName: "Detect Worker"
    )
    let timeline = makeTimelineEntries(
      sessionID: "sess-detect",
      agentID: "leader-detect",
      summary: "Checkpoint"
    )
    await store.cacheSessionDetail(detail, timeline: timeline)

    let afterHydration = await store.persistedSnapshotHydrationQueue(
      for: [session]
    )
    #expect(afterHydration.isEmpty)
  }

  @Test("Hydration queue detects session without timeline as needing hydration")
  func hydrationQueueDetectsNoTimeline() async throws {
    let store = makeStore()
    let project = makeProject(totalSessionCount: 1, activeSessionCount: 1)
    let session = makeSession(.init(
      sessionId: "sess-notimeline",
      context: "No timeline",
      status: .active,
      leaderId: "leader-notimeline",
      openTaskCount: 0,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 1
    ))

    await store.cacheSessionList([session], projects: [project])
    let detail = SessionDetail(
      session: session,
      agents: [],
      tasks: [],
      signals: [],
      observer: nil,
      agentActivity: []
    )
    await store.cacheSessionDetail(detail, timeline: [])

    let queue = await store.persistedSnapshotHydrationQueue(for: [session])
    #expect(!queue.isEmpty)
  }

  // MARK: - Scoped hydration queue fetch

  @Test("Hydration queue only checks sessions matching input")
  func hydrationQueueScopedToInput() async throws {
    let store = makeStore()
    let project = makeProject(totalSessionCount: 3, activeSessionCount: 3)

    let sessions = (0..<3).map { index in
      makeSession(.init(
        sessionId: "sess-scope-\(index)",
        context: "Scope \(index)",
        status: .active,
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))
    }

    await store.cacheSessionList(sessions, projects: [project])

    let subset = [sessions[1]]
    let queue = await store.persistedSnapshotHydrationQueue(for: subset)
    #expect(queue.count == 1)
    #expect(queue.first?.sessionId == "sess-scope-1")
  }

  // MARK: - Identity map release

  @Test("Sequential cache operations release context between calls")
  func sequentialOperationsReleaseContext() async throws {
    let store = makeStore()
    let project = makeProject(totalSessionCount: 20, activeSessionCount: 20)

    for index in 0..<20 {
      let session = makeSession(.init(
        sessionId: "seq-\(index)",
        context: "Sequential \(index)",
        status: .active,
        leaderId: "leader-seq-\(index)",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 2
      ))
      let detail = makeSessionDetail(
        summary: session,
        workerID: "worker-seq-\(index)",
        workerName: "Worker \(index)"
      )
      let timeline = (0..<50).map { entryIndex in
        TimelineEntry(
          entryId: "seq-\(index)-entry-\(entryIndex)",
          recordedAt: "2026-04-01T00:00:00Z",
          kind: "task_checkpoint",
          sessionId: "seq-\(index)",
          agentId: "leader-seq-\(index)",
          taskId: nil,
          summary: "Entry \(entryIndex)",
          payload: .object([:])
        )
      }

      await store.cacheSessionList([session], projects: [project])
      await store.cacheSessionDetail(detail, timeline: timeline)
    }

    let sessionDescriptor = FetchDescriptor<CachedSession>()
    let storedSessions = try container.mainContext.fetch(sessionDescriptor)
    #expect(storedSessions.count == 20)

    let timelineDescriptor = FetchDescriptor<CachedTimelineEntry>()
    let storedTimeline = try container.mainContext.fetch(timelineDescriptor)
    #expect(storedTimeline.count == 20 * 50)

    let agentDescriptor = FetchDescriptor<CachedAgent>()
    let storedAgents = try container.mainContext.fetch(agentDescriptor)
    #expect(storedAgents.count == 20 * 2)
  }

  // MARK: - Recently viewed session IDs

  @Test("Hydration scoped to recently viewed sessions")
  func hydrationScopedToRecentlyViewed() async throws {
    let store = makeStore()
    let project = makeProject(totalSessionCount: 3, activeSessionCount: 3)

    let sessions = (0..<3).map { index in
      makeSession(.init(
        sessionId: "sess-recent-\(index)",
        context: "Recent \(index)",
        status: .active,
        leaderId: "leader-recent-\(index)",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))
    }

    await store.cacheSessionList(sessions, projects: [project])

    for session in sessions {
      let detail = makeSessionDetail(
        summary: session,
        workerID: "worker-\(session.sessionId)",
        workerName: "Worker"
      )
      let timeline = makeTimelineEntries(
        sessionID: session.sessionId,
        agentID: session.leaderId ?? "",
        summary: "Entry"
      )
      await store.cacheSessionDetail(
        detail,
        timeline: timeline,
        markViewed: session.sessionId == "sess-recent-1"
      )
    }

    var detailsByID: [String: SessionDetail] = [:]
    var timelinesByID: [String: [TimelineEntry]] = [:]
    for session in sessions {
      detailsByID[session.sessionId] = makeSessionDetail(
        summary: session,
        workerID: "worker-\(session.sessionId)",
        workerName: "Worker"
      )
      timelinesByID[session.sessionId] = makeTimelineEntries(
        sessionID: session.sessionId,
        agentID: session.leaderId ?? "",
        summary: "Updated entry"
      )
    }

    let client = RecordingHarnessClient()
    client.configureSessions(
      summaries: sessions,
      detailsByID: detailsByID,
      timelinesBySessionID: timelinesByID
    )

    let updatedSessions = sessions.map { original in
      SessionSummary(
        projectId: original.projectId,
        projectName: original.projectName,
        projectDir: original.projectDir,
        contextRoot: original.contextRoot,
        sessionId: original.sessionId,
        title: original.title,
        context: original.context,
        status: original.status,
        createdAt: original.createdAt,
        updatedAt: "2026-04-02T00:00:00Z",
        lastActivityAt: "2026-04-02T00:00:00Z",
        leaderId: original.leaderId,
        observeId: original.observeId,
        pendingLeaderTransfer: original.pendingLeaderTransfer,
        metrics: original.metrics
      )
    }

    store.connectionState = .online
    store.schedulePersistedSnapshotHydration(
      using: client,
      sessions: updatedSessions
    )
    try await Task.sleep(for: .milliseconds(200))

    let totalDetailCalls =
      client.readCallCount(.sessionDetail("sess-recent-0"))
      + client.readCallCount(.sessionDetail("sess-recent-1"))
      + client.readCallCount(.sessionDetail("sess-recent-2"))

    #expect(totalDetailCalls <= 1)

    #expect(client.readCallCount(.sessionDetail("sess-recent-0")) == 0)
    #expect(client.readCallCount(.sessionDetail("sess-recent-2")) == 0)
  }
}
