import Foundation
import SwiftData
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Session cache timeline memory fixes")
struct SessionCacheTimelineMemoryTests {
  let harness: SessionCacheMemoryTestHarness

  init() throws {
    harness = try SessionCacheMemoryTestHarness()
  }

  @Test("syncTimeline caps entries at 300 per session")
  func syncTimelineCapsAt300() async throws {
    let store = harness.makeStore()
    let session = makeSession(
      .init(
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
          index / 3600,
          (index / 60) % 60,
          index % 60
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
    let stored = try harness.container.mainContext.fetch(descriptor)
    #expect(stored.count == 300)

    let storedIds = Set(stored.map(\.entryId))
    #expect(storedIds.contains("entry-499"))
    #expect(storedIds.contains("entry-200"))
    #expect(!storedIds.contains("entry-0"))
    #expect(!storedIds.contains("entry-199"))
  }

  @Test("syncTimeline trims existing entries beyond cap on update")
  func syncTimelineTrimsOnUpdate() async throws {
    let store = harness.makeStore()
    let session = makeSession(
      .init(
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
    let stored = try harness.container.mainContext.fetch(descriptor)
    #expect(stored.count == 300)

    let storedIds = Set(stored.map(\.entryId))
    #expect(!storedIds.contains("old-0"))
    #expect(storedIds.contains("new-349"))
    #expect(storedIds.contains("new-50"))
    #expect(!storedIds.contains("new-49"))
  }

  @Test("syncTimeline keeps all entries when under cap")
  func syncTimelineKeepsAllUnderCap() async throws {
    let store = harness.makeStore()
    let session = makeSession(
      .init(
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
    let stored = try harness.container.mainContext.fetch(descriptor)
    #expect(stored.count == 50)
  }

  @Test("Sequential cache operations release context between calls")
  func sequentialOperationsReleaseContext() async throws {
    let store = harness.makeStore()
    let project = makeProject(totalSessionCount: 20, activeSessionCount: 20)

    var allSessions: [SessionSummary] = []
    for index in 0..<20 {
      let session = makeSession(
        .init(
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

      allSessions.append(session)
      await store.cacheSessionList(allSessions, projects: [project])
      await store.cacheSessionDetail(detail, timeline: timeline)
    }

    let sessionDescriptor = FetchDescriptor<CachedSession>()
    let storedSessions = try harness.container.mainContext.fetch(sessionDescriptor)
    #expect(storedSessions.count == 20)

    let timelineDescriptor = FetchDescriptor<CachedTimelineEntry>()
    let storedTimeline = try harness.container.mainContext.fetch(timelineDescriptor)
    #expect(storedTimeline.count == 20 * 50)

    let agentDescriptor = FetchDescriptor<CachedAgent>()
    let storedAgents = try harness.container.mainContext.fetch(agentDescriptor)
    #expect(storedAgents.count == 20 * 2)
  }
}
