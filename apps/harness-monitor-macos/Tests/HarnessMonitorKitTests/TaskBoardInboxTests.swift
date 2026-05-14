import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Task board inbox scaffold")
@MainActor
struct TaskBoardInboxTests {
  @Test("Snapshot groups cached tasks into inbox lanes")
  func snapshotGroupsTasksIntoInboxLanes() {
    let session = makeTaskBoardSession()
    let detail = SessionDetail(
      session: session,
      agents: [],
      tasks: [
        makeTask(id: "done", status: .done, severity: .critical, updatedAt: "2026-05-14T10:00:00Z"),
        makeTask(
          id: "blocked", status: .blocked, severity: .medium, updatedAt: "2026-05-14T09:00:00Z"),
        makeTask(
          id: "review", status: .awaitingReview, severity: .high,
          updatedAt: "2026-05-14T08:00:00Z"),
        makeTask(id: "active", status: .inProgress, severity: .low, updatedAt: "2026-05-14T07:00:00Z"),
        makeTask(id: "open", status: .open, severity: .critical, updatedAt: "2026-05-14T06:00:00Z"),
      ],
      signals: [],
      observer: nil,
      agentActivity: []
    )

    let snapshot = TaskBoardInboxSnapshot(
      sessions: [session],
      detailsBySessionID: [session.sessionId: detail],
      generatedAt: nil,
      isFromCache: true
    )

    #expect(snapshot.items.map { $0.task.taskId } == ["blocked", "review", "active", "open"])
    #expect(snapshot.blockedItemCount == 1)
    #expect(snapshot.reviewItemCount == 1)
    #expect(snapshot.openItemCount == 3)
    #expect(snapshot.sections.map(\.lane) == TaskBoardInboxLane.allCases)
  }

  @Test("Cache loader reads persisted task detail snapshots")
  func cacheLoaderReadsPersistedTaskDetails() async throws {
    let harness = try PersistenceIntegrationTestHarness()
    let cacheService = SessionCacheService(modelContainer: harness.container)
    let project = makeProject(totalSessionCount: 1, activeSessionCount: 1)
    let session = makeTaskBoardSession()
    let detail = SessionDetail(
      session: session,
      agents: [],
      tasks: [
        makeTask(id: "cached-open", status: .open, severity: .high, updatedAt: "2026-05-14T10:00:00Z")
      ],
      signals: [],
      observer: nil,
      agentActivity: []
    )

    _ = await cacheService.cacheSessionList([session], projects: [project])
    _ = await cacheService.cacheSessionDetail(detail, timeline: [])

    let snapshot = await TaskBoardInboxCache(
      sessionCache: cacheService,
      now: { Date(timeIntervalSinceReferenceDate: 801_000_000) }
    ).loadSnapshot()

    #expect(snapshot.isFromCache)
    #expect(snapshot.items.map { $0.task.taskId } == ["cached-open"])
    #expect(snapshot.generatedAt == Date(timeIntervalSinceReferenceDate: 801_000_000))
  }

  private func makeTaskBoardSession() -> SessionSummary {
    makeSession(
      SessionFixture(
        sessionId: "sess-task-board-inbox",
        title: "Task Board Inbox",
        context: "Task board inbox test",
        status: .active,
        leaderId: "leader-task-board",
        openTaskCount: 1,
        inProgressTaskCount: 1,
        blockedTaskCount: 1,
        activeAgentCount: 2
      ))
  }

  private func makeTask(
    id: String,
    status: TaskStatus,
    severity: TaskSeverity,
    updatedAt: String
  ) -> WorkItem {
    WorkItem(
      taskId: id,
      title: "Task \(id)",
      context: nil,
      severity: severity,
      status: status,
      assignedTo: nil,
      createdAt: "2026-05-14T06:00:00Z",
      updatedAt: updatedAt,
      createdBy: nil,
      notes: [],
      suggestedFix: nil,
      source: .manual,
      blockedReason: nil,
      completedAt: nil,
      checkpointSummary: nil
    )
  }
}
