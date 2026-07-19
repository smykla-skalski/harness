import HarnessMonitorKit
import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Task board overview actions")
struct TaskBoardOverviewActionsTests {
  @Test("Stale api move is rejected")
  func staleAPIMoveRejected() {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .empty)
    store.globalTaskBoardItems = [Self.makeAPIItem(id: "item-a", status: .inProgress)]
    let actions = TaskBoardOverviewActions(store: store, scope: .dashboard)

    // Payload captured `.todo` as the source status, but the live item has
    // since moved to `.inProgress` (e.g. the orchestrator advanced it).
    let dragItem = TaskBoardCardDragItem.api(itemID: "item-a", status: .todo)

    #expect(!actions.moveCards([dragItem], to: .inReview))
  }

  @Test("Fresh api move submits")
  func freshAPIMoveSubmits() {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .empty)
    store.globalTaskBoardItems = [Self.makeAPIItem(id: "item-b", status: .todo)]
    let actions = TaskBoardOverviewActions(store: store, scope: .dashboard)

    let dragItem = TaskBoardCardDragItem.api(itemID: "item-b", status: .todo)

    #expect(actions.moveCards([dragItem], to: .inProgress))
  }

  @Test("Stale selected-session inbox move is rejected")
  func staleSelectedSessionInboxMoveRejected() {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .empty)
    store.selectedSessionID = "session-a"
    store.selectedSession = Self.makeSessionDetail(
      sessionID: "session-a",
      tasks: [Self.makeWorkItem(taskId: "task-a", status: .inProgress)]
    )
    let actions = TaskBoardOverviewActions(store: store, scope: .dashboard)

    // Payload captured the task in the backlog lane with `.open` status, but
    // the selected session's live copy has since moved to `.inProgress`.
    let dragItem = TaskBoardCardDragItem.inbox(
      sessionID: "session-a",
      taskID: "task-a",
      status: .open,
      sourceLaneRawValue: TaskBoardInboxLane.backlog.rawValue
    )

    #expect(!actions.moveCards([dragItem], to: .inReview))
  }

  @Test("Non-selected-session inbox move is accepted without local validation")
  func nonSelectedSessionInboxMoveAccepted() {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .empty)
    store.selectedSessionID = "session-other"
    store.selectedSession = nil
    let actions = TaskBoardOverviewActions(store: store, scope: .dashboard)

    // "task-a" belongs to a session that isn't locally selected/cached, so
    // there is no live copy to re-validate against - the payload is trusted
    // and the server stays authoritative.
    let dragItem = TaskBoardCardDragItem.inbox(
      sessionID: "session-a",
      taskID: "task-a",
      status: .open,
      sourceLaneRawValue: TaskBoardInboxLane.backlog.rawValue
    )

    #expect(actions.moveCards([dragItem], to: .inProgress))
  }

  @Test("Report drop rejection forwards the reason to the store as failure feedback")
  func reportDropRejectionForwardsToStore() {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .empty)
    let actions = TaskBoardOverviewActions(store: store, scope: .dashboard)

    actions.reportDropRejection("Cannot move task: an action is already in progress")

    #expect(
      store.toast.activeFeedback.last?.message
        == "Cannot move task: an action is already in progress"
    )
    #expect(store.toast.activeFeedback.last?.severity == .failure)
  }

  @Test("Report drop rejection stays inert with no store")
  func reportDropRejectionStaysInertWithNoStore() {
    let actions = TaskBoardOverviewActions(store: nil, scope: .dashboard)

    actions.reportDropRejection("Cannot move task: an action is already in progress")
  }

  private static func makeAPIItem(id: String, status: TaskBoardStatus) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: "Fixture board item",
      body: "",
      status: status,
      priority: .medium,
      tags: [],
      projectId: nil,
      agentMode: .interactive,
      externalRefs: [],
      planning: TaskBoardPlanningState(),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      createdAt: "2026-05-19T10:10:00Z",
      updatedAt: "2026-05-19T10:11:00Z",
      deletedAt: nil
    )
  }

  private static func makeWorkItem(taskId: String, status: TaskStatus) -> WorkItem {
    WorkItem(
      taskId: taskId,
      title: "Fixture task",
      context: "fixture",
      severity: .medium,
      status: status,
      assignedTo: nil,
      createdAt: "2026-05-19T10:10:00Z",
      updatedAt: "2026-05-19T10:11:00Z",
      createdBy: "fixture",
      notes: [],
      suggestedFix: nil,
      source: .manual,
      blockedReason: nil,
      completedAt: nil,
      checkpointSummary: nil
    )
  }

  private static func makeSessionDetail(sessionID: String, tasks: [WorkItem]) -> SessionDetail {
    SessionDetail(
      session: SessionSummary(
        projectId: "project-fixture",
        projectName: "harness",
        projectDir: "/Users/example/Projects/harness",
        contextRoot: "/Users/example/Library/Application Support/harness/sessions/harness",
        sessionId: sessionID,
        worktreePath: "/Users/example/Library/Application Support/harness/fixture/workspace",
        sharedPath: "/Users/example/Library/Application Support/harness/fixture/memory",
        originPath: "/Users/example/Projects/harness",
        branchRef: "harness/fixture",
        title: "Fixture session",
        context: "Fixture session for actions tests.",
        status: .active,
        createdAt: "2026-05-19T09:00:00Z",
        updatedAt: "2026-05-19T10:00:00Z",
        lastActivityAt: "2026-05-19T10:00:00Z",
        leaderId: "leader-fixture",
        observeId: nil,
        pendingLeaderTransfer: nil,
        metrics: SessionMetrics(
          agentCount: 1,
          activeAgentCount: 1,
          openTaskCount: tasks.count,
          inProgressTaskCount: 0,
          awaitingReviewTaskCount: 0,
          blockedTaskCount: 0,
          completedTaskCount: 0
        )
      ),
      agents: [],
      tasks: tasks,
      signals: [],
      observer: nil,
      agentActivity: []
    )
  }
}
