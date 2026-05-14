import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Task board inbox scaffold")
@MainActor
struct TaskBoardInboxTests {
  @Test("Inbox lanes use global board ordering")
  func inboxLanesUseGlobalBoardOrdering() {
    #expect(
      TaskBoardInboxLane.allCases == [
        .needsYou,
        .ready,
        .running,
        .review,
        .blocked,
        .backlog,
      ])
  }

  @Test("Snapshot groups cached tasks into global board lanes")
  func snapshotGroupsTasksIntoGlobalBoardLanes() {
    let session = makeTaskBoardSession()
    let detail = SessionDetail(
      session: session,
      agents: [],
      tasks: [
        makeTask(
          id: "done",
          status: .done,
          severity: .critical,
          updatedAt: "2026-05-14T10:00:00Z"
        ),
        makeTask(
          id: "blocked",
          status: .blocked,
          severity: .medium,
          updatedAt: "2026-05-14T09:00:00Z"
        ),
        makeTask(
          id: "review",
          status: .awaitingReview,
          severity: .high,
          updatedAt: "2026-05-14T08:00:00Z"
        ),
        makeTask(
          id: "running",
          status: .inProgress,
          severity: .low,
          updatedAt: "2026-05-14T07:00:00Z"
        ),
        makeTask(
          id: "ready",
          status: .open,
          severity: .medium,
          updatedAt: "2026-05-14T06:30:00Z",
          assignedTo: "worker-1"
        ),
        makeTask(
          id: "backlog",
          status: .open,
          severity: .critical,
          updatedAt: "2026-05-14T06:00:00Z"
        ),
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

    #expect(
      snapshot.items.map { $0.task.taskId } == [
        "ready",
        "running",
        "review",
        "blocked",
        "backlog",
      ])
    #expect(
      snapshot.items.map(\.lane) == [
        .ready,
        .running,
        .review,
        .blocked,
        .backlog,
      ])
    #expect(snapshot.needsYouItemCount == 0)
    #expect(snapshot.blockedItemCount == 1)
    #expect(snapshot.reviewItemCount == 1)
    #expect(snapshot.openItemCount == 5)
    #expect(snapshot.visibleItemCount == 5)
    #expect(snapshot.sections.map(\.lane) == TaskBoardInboxLane.allCases)
  }

  @Test("Work item status maps to global board lanes")
  func workItemStatusMapsToGlobalBoardLanes() {
    #expect(TaskBoardInboxLane(status: TaskStatus.blocked) == .blocked)
    #expect(TaskBoardInboxLane(status: TaskStatus.awaitingReview) == .review)
    #expect(TaskBoardInboxLane(status: TaskStatus.inReview) == .review)
    #expect(TaskBoardInboxLane(status: TaskStatus.inProgress) == .running)
    #expect(TaskBoardInboxLane(status: TaskStatus.open) == .backlog)
    #expect(TaskBoardInboxLane(status: TaskStatus.done) == nil)

    #expect(
      TaskBoardInboxLane(
        task: makeTask(
          id: "assigned",
          status: .open,
          severity: .medium,
          updatedAt: "2026-05-14T08:00:00Z",
          assignedTo: "worker-1"
        )
      ) == .ready
    )
    #expect(
      TaskBoardInboxLane(
        task: makeTask(
          id: "queued",
          status: .open,
          severity: .medium,
          updatedAt: "2026-05-14T08:00:00Z",
          queuedAt: "2026-05-14T08:01:00Z"
        )
      ) == .ready
    )
  }

  @Test("Task board item status maps to global board lanes")
  func taskBoardItemStatusMapsToGlobalBoardLanes() {
    #expect(TaskBoardInboxLane(status: TaskBoardStatus.planReview) == .needsYou)
    #expect(TaskBoardInboxLane(status: TaskBoardStatus.blocked) == .blocked)
    #expect(TaskBoardInboxLane(status: TaskBoardStatus.todo) == .ready)
    #expect(TaskBoardInboxLane(status: TaskBoardStatus.inProgress) == .running)
    #expect(TaskBoardInboxLane(status: TaskBoardStatus.inReview) == .review)
    #expect(TaskBoardInboxLane(status: TaskBoardStatus.new) == .backlog)
    #expect(TaskBoardInboxLane(status: TaskBoardStatus.planning) == .backlog)
    #expect(TaskBoardInboxLane(status: TaskBoardStatus.done) == nil)

    #expect(
      TaskBoardInboxLane(taskBoardItem: makeTaskBoardItem(status: .planReview)) == .needsYou
    )
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
        makeTask(
          id: "cached-open",
          status: .open,
          severity: .high,
          updatedAt: "2026-05-14T10:00:00Z"
        )
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
    updatedAt: String,
    assignedTo: String? = nil,
    queuedAt: String? = nil
  ) -> WorkItem {
    WorkItem(
      taskId: id,
      title: "Task \(id)",
      context: nil,
      severity: severity,
      status: status,
      assignedTo: assignedTo,
      queuedAt: queuedAt,
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

  private func makeTaskBoardItem(status: TaskBoardStatus) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: "board-\(status.rawValue)",
      title: "Task board \(status.rawValue)",
      body: "",
      status: status,
      priority: .medium,
      tags: [],
      projectId: nil,
      agentMode: .headless,
      externalRefs: [],
      planning: TaskBoardPlanningState(),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      createdAt: "2026-05-14T06:00:00Z",
      updatedAt: "2026-05-14T07:00:00Z",
      deletedAt: nil
    )
  }
}
