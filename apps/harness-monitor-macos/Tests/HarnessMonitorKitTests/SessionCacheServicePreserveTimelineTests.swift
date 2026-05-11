import SwiftData
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class SessionCacheServicePreserveTimelineTests: XCTestCase {
  func testCacheSessionDetailPreservesTimelineWhenFlagSet() async throws {
    let harness = try PersistenceIntegrationTestHarness()
    let cacheService = SessionCacheService(modelContainer: harness.container)

    let session = makeSession(makePreserveTimelineFixture())
    let originalDetail = makeSessionDetail(
      summary: session,
      workerID: "worker-preserve",
      workerName: "Preserve Worker"
    )
    let originalTimeline = [
      TimelineEntry(
        entryId: "evt-1",
        recordedAt: "2026-05-11T12:00:00Z",
        kind: "task.updated",
        sessionId: session.sessionId,
        agentId: originalDetail.agents[0].agentId,
        taskId: "task-fixture",
        summary: "First event",
        payload: .null
      )
    ]
    _ = await cacheService.cacheSessionDetail(
      originalDetail,
      timeline: originalTimeline
    )

    let renamedWorker = AgentRegistration(
      agentId: "worker-preserve-new",
      name: "Preserve Worker v2",
      runtime: "codex",
      role: .worker,
      capabilities: ["general"],
      joinedAt: session.createdAt,
      updatedAt: "2026-05-11T13:00:00Z",
      status: .active,
      agentSessionId: "worker-preserve-new-session",
      lastActivityAt: "2026-05-11T13:00:00Z",
      currentTaskId: nil,
      runtimeCapabilities: originalDetail.agents[0].runtimeCapabilities,
      persona: nil
    )
    let updatedDetail = SessionDetail(
      session: originalDetail.session,
      agents: [renamedWorker],
      tasks: originalDetail.tasks,
      signals: originalDetail.signals,
      observer: originalDetail.observer,
      agentActivity: originalDetail.agentActivity
    )

    _ = await cacheService.cacheSessionDetail(
      updatedDetail,
      timeline: [],
      preservesTimeline: true
    )

    let loaded = await cacheService.loadSessionDetail(sessionID: session.sessionId)
    let cached = try XCTUnwrap(loaded)
    XCTAssertEqual(
      cached.detail.agents.map(\.agentId),
      ["worker-preserve-new"],
      "Detail must reflect the new push payload"
    )
    XCTAssertEqual(
      cached.timeline.count,
      1,
      "Preserving timeline must not wipe the cached entries"
    )
    XCTAssertEqual(cached.timeline.first?.entryId, "evt-1")
  }

  func testCacheSessionDetailOverwritesTimelineByDefault() async throws {
    let harness = try PersistenceIntegrationTestHarness()
    let cacheService = SessionCacheService(modelContainer: harness.container)

    let session = makeSession(makePreserveTimelineFixture())
    let detail = makeSessionDetail(
      summary: session,
      workerID: "worker-overwrite",
      workerName: "Overwrite Worker"
    )
    let originalTimeline = [
      TimelineEntry(
        entryId: "evt-old",
        recordedAt: "2026-05-11T12:00:00Z",
        kind: "task.updated",
        sessionId: session.sessionId,
        agentId: detail.agents[0].agentId,
        taskId: "task-fixture",
        summary: "Old",
        payload: .null
      )
    ]
    _ = await cacheService.cacheSessionDetail(detail, timeline: originalTimeline)

    _ = await cacheService.cacheSessionDetail(detail, timeline: [])

    let loaded = await cacheService.loadSessionDetail(sessionID: session.sessionId)
    let cached = try XCTUnwrap(loaded)
    XCTAssertTrue(
      cached.timeline.isEmpty,
      "Default behaviour must replace the cached timeline with the supplied one"
    )
  }

  private func makePreserveTimelineFixture() -> SessionFixture {
    SessionFixture(
      sessionId: "sess-preserve-timeline",
      context: "Preserve timeline",
      status: .active,
      leaderId: "leader-preserve",
      openTaskCount: 1,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 2
    )
  }
}
