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
        .backlog,
        .todo,
        .planning,
        .inProgress,
        .agenticReview,
        .testing,
        .inReview,
        .toReview,
        .humanRequired,
        .failed,
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
        "backlog",
        "ready",
        "running",
        "review",
        "blocked",
      ])
    #expect(
      snapshot.items.map(\.lane) == [
        .backlog,
        .todo,
        .inProgress,
        .toReview,
        .failed,
      ])
    #expect(snapshot.needsYouItemCount == 0)
    #expect(snapshot.blockedItemCount == 1)
    #expect(snapshot.reviewItemCount == 1)
    #expect(snapshot.completedItemCount == 0)
    #expect(snapshot.openItemCount == 5)
    #expect(snapshot.visibleItemCount == 5)
    #expect(snapshot.sections.map(\.lane) == TaskBoardInboxLane.allCases)
  }

  @Test("Work item status maps to global board lanes")
  func workItemStatusMapsToGlobalBoardLanes() {
    #expect(TaskBoardInboxLane(status: TaskStatus.blocked) == .failed)
    #expect(TaskBoardInboxLane(status: TaskStatus.awaitingReview) == .toReview)
    #expect(TaskBoardInboxLane(status: TaskStatus.inReview) == .inReview)
    #expect(TaskBoardInboxLane(status: TaskStatus.inProgress) == .inProgress)
    #expect(TaskBoardInboxLane(status: TaskStatus.open) == .backlog)
    #expect(TaskBoardInboxLane(status: TaskStatus.done) == nil)

    #expect(
      TaskBoardInboxLane(
        task: makeTask(
          id: "unassigned",
          status: .open,
          severity: .medium,
          updatedAt: "2026-05-14T08:00:00Z"
        )
      ) == .backlog
    )
    #expect(
      TaskBoardInboxLane(
        task: makeTask(
          id: "assigned",
          status: .open,
          severity: .medium,
          updatedAt: "2026-05-14T08:00:00Z",
          assignedTo: "worker-1"
        )
      ) == .todo
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
      ) == .todo
    )
  }

  @Test("Task board item status maps to global board lanes")
  func taskBoardItemStatusMapsToGlobalBoardLanes() {
    #expect(TaskBoardInboxLane(status: TaskBoardStatus.backlog) == .backlog)
    #expect(TaskBoardInboxLane(status: TaskBoardStatus.todo) == .todo)
    #expect(TaskBoardInboxLane(status: TaskBoardStatus.planning) == .planning)
    #expect(TaskBoardInboxLane(status: TaskBoardStatus.inProgress) == .inProgress)
    #expect(TaskBoardInboxLane(status: TaskBoardStatus.agenticReview) == .agenticReview)
    #expect(TaskBoardInboxLane(status: TaskBoardStatus.testing) == .testing)
    #expect(TaskBoardInboxLane(status: TaskBoardStatus.inReview) == .inReview)
    #expect(TaskBoardInboxLane(status: TaskBoardStatus.toReview) == .toReview)
    #expect(TaskBoardInboxLane(status: TaskBoardStatus.humanRequired) == .humanRequired)
    #expect(TaskBoardInboxLane(status: TaskBoardStatus.failed) == .failed)
    #expect(TaskBoardInboxLane(status: TaskBoardStatus.done) == nil)

    #expect(TaskBoardInboxLane(status: TaskBoardStatus.new) == .todo)
    #expect(TaskBoardInboxLane(status: TaskBoardStatus.planReview) == .agenticReview)
    #expect(TaskBoardInboxLane(status: TaskBoardStatus.needsYou) == .humanRequired)
    #expect(TaskBoardInboxLane(status: TaskBoardStatus.blocked) == .failed)

    #expect(
      TaskBoardInboxLane(taskBoardItem: makeTaskBoardItem(status: .agenticReview))
        == .agenticReview
    )
    #expect(
      TaskBoardInboxLane(taskBoardItem: makeTaskBoardItem(status: .humanRequired))
        == .humanRequired
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

  @Test("Cache loader can aggregate only visible sessions")
  func cacheLoaderAggregatesOnlyVisibleSessions() async throws {
    let harness = try PersistenceIntegrationTestHarness()
    let cacheService = SessionCacheService(modelContainer: harness.container)
    let project = makeProject(totalSessionCount: 2, activeSessionCount: 2)
    let visibleSession = makeTaskBoardSession()
    let hiddenSession = makeSession(
      SessionFixture(
        sessionId: "sess-hidden-task-board-inbox",
        title: "Hidden Task Board Inbox",
        context: "Hidden task board inbox test",
        status: .active,
        leaderId: "leader-hidden-task-board",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))
    let visibleDetail = SessionDetail(
      session: visibleSession,
      agents: [],
      tasks: [
        makeTask(
          id: "visible-open",
          status: .open,
          severity: .high,
          updatedAt: "2026-05-14T10:00:00Z"
        )
      ],
      signals: [],
      observer: nil,
      agentActivity: []
    )
    let hiddenDetail = SessionDetail(
      session: hiddenSession,
      agents: [],
      tasks: [
        makeTask(
          id: "hidden-open",
          status: .open,
          severity: .critical,
          updatedAt: "2026-05-14T11:00:00Z"
        )
      ],
      signals: [],
      observer: nil,
      agentActivity: []
    )

    _ = await cacheService.cacheSessionList([visibleSession, hiddenSession], projects: [project])
    _ = await cacheService.cacheSessionDetail(visibleDetail, timeline: [])
    _ = await cacheService.cacheSessionDetail(hiddenDetail, timeline: [])

    let snapshot = await TaskBoardInboxCache(sessionCache: cacheService)
      .loadSnapshot(sessions: [visibleSession])

    #expect(snapshot.items.map { $0.task.taskId } == ["visible-open"])
    #expect(snapshot.items.map { $0.session.sessionId } == [visibleSession.sessionId])
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
