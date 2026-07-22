import SwiftUI
import Testing

@testable import HarnessMonitorKit
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

    #expect(
      !actions.moveCards(
        [dragItem],
        to: .inReview,
        liveInboxItems: TaskBoardLiveInboxItems()
      )
    )
  }

  @Test("Fresh api move submits")
  func freshAPIMoveSubmits() {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .empty)
    store.globalTaskBoardItems = [Self.makeAPIItem(id: "item-b", status: .todo)]
    let actions = TaskBoardOverviewActions(store: store, scope: .dashboard)

    let dragItem = TaskBoardCardDragItem.api(itemID: "item-b", status: .todo)

    #expect(
      actions.moveCards(
        [dragItem],
        to: .inProgress,
        liveInboxItems: TaskBoardLiveInboxItems()
      )
    )
  }

  @Test("Moving an umbrella card off its lane is accepted like any other status move")
  func movingUmbrellaCardOffItsLaneIsAccepted() {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .empty)
    store.globalTaskBoardItems = [
      Self.makeAPIItem(id: "item-umbrella", status: .todo, kind: .umbrella)
    ]
    let actions = TaskBoardOverviewActions(store: store, scope: .dashboard)
    let dragItem = TaskBoardCardDragItem.api(
      itemID: "item-umbrella", status: .todo, kind: .umbrella)

    #expect(
      actions.moveCards(
        [dragItem],
        to: .inProgress,
        liveInboxItems: TaskBoardLiveInboxItems()
      )
    )
  }

  @Test("Stale selected-session inbox move is rejected")
  func staleSelectedSessionInboxMoveRejected() {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .empty)
    store.selectedSessionID = "session-a"
    let currentTask = Self.makeWorkItem(taskId: "task-a", status: .inProgress)
    store.selectedSession = Self.makeSessionDetail(sessionID: "session-a", tasks: [currentTask])
    let actions = TaskBoardOverviewActions(store: store, scope: .dashboard)
    let liveInboxItems = Self.makeLiveInboxItems(sessionID: "session-a", task: currentTask)

    // Payload captured the task in the backlog lane with `.open` status, but
    // the selected session's live copy has since moved to `.inProgress`.
    let dragItem = TaskBoardCardDragItem.inbox(
      sessionID: "session-a",
      taskID: "task-a",
      status: .open,
      sourceLaneRawValue: TaskBoardInboxLane.backlog.rawValue
    )

    #expect(!actions.moveCards([dragItem], to: .inReview, liveInboxItems: liveInboxItems))
  }

  @Test("Stale non-selected-session inbox status is rejected")
  func staleNonSelectedSessionInboxStatusRejected() {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .empty)
    store.selectedSessionID = "session-other"
    store.selectedSession = nil
    let actions = TaskBoardOverviewActions(store: store, scope: .dashboard)
    let currentTask = Self.makeWorkItem(taskId: "task-a", status: .inProgress)
    let liveInboxItems = Self.makeLiveInboxItems(sessionID: "session-a", task: currentTask)

    let dragItem = TaskBoardCardDragItem.inbox(
      sessionID: "session-a",
      taskID: "task-a",
      status: .open,
      sourceLaneRawValue: TaskBoardInboxLane.backlog.rawValue
    )

    #expect(!actions.moveCards([dragItem], to: .inReview, liveInboxItems: liveInboxItems))
  }

  @Test("Stale non-selected-session inbox lane is rejected")
  func staleNonSelectedSessionInboxLaneRejected() {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .empty)
    store.selectedSessionID = "session-other"
    store.selectedSession = nil
    let actions = TaskBoardOverviewActions(store: store, scope: .dashboard)
    let currentTask = Self.makeWorkItem(
      taskId: "task-a",
      status: .open,
      assignedTo: "agent-a"
    )
    let liveInboxItems = Self.makeLiveInboxItems(sessionID: "session-a", task: currentTask)
    let dragItem = TaskBoardCardDragItem.inbox(
      sessionID: "session-a",
      taskID: "task-a",
      status: .open,
      sourceLaneRawValue: TaskBoardInboxLane.backlog.rawValue
    )

    #expect(!actions.moveCards([dragItem], to: .inProgress, liveInboxItems: liveInboxItems))
  }

  @Test("Fresh non-selected-session inbox move submits")
  func freshNonSelectedSessionInboxMoveSubmits() {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .empty)
    store.selectedSessionID = "session-other"
    store.selectedSession = nil
    let actions = TaskBoardOverviewActions(store: store, scope: .dashboard)
    let currentTask = Self.makeWorkItem(taskId: "task-a", status: .open)
    let liveInboxItems = Self.makeLiveInboxItems(sessionID: "session-a", task: currentTask)
    let dragItem = TaskBoardCardDragItem.inbox(
      sessionID: "session-a",
      taskID: "task-a",
      status: .open,
      sourceLaneRawValue: TaskBoardInboxLane.backlog.rawValue
    )

    #expect(actions.moveCards([dragItem], to: .inProgress, liveInboxItems: liveInboxItems))
  }

  @Test("Inbox move missing from the rendered lookup is rejected")
  func missingRenderedInboxMoveRejected() {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .empty)
    let actions = TaskBoardOverviewActions(store: store, scope: .dashboard)
    let dragItem = TaskBoardCardDragItem.inbox(
      sessionID: "session-a",
      taskID: "task-a",
      status: .open,
      sourceLaneRawValue: TaskBoardInboxLane.backlog.rawValue
    )

    #expect(
      !actions.moveCards(
        [dragItem],
        to: .inProgress,
        liveInboxItems: TaskBoardLiveInboxItems()
      )
    )
  }

  @Test("Delete capability mirrors store readiness")
  func deleteCapabilityMirrorsStoreReadiness() {
    let readyStore = HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded)
    let readyActions = TaskBoardOverviewActions(store: readyStore, scope: .dashboard)

    #expect(readyActions.canDeleteItem)
    #expect(readyActions.canDeleteTargets)

    readyStore.beginDaemonAction()
    #expect(!readyActions.canDeleteItem)
    #expect(!readyActions.canDeleteTargets)
    readyStore.endDaemonAction()

    readyStore.isSessionActionInFlight = true
    #expect(!readyActions.canDeleteItem)
    #expect(!readyActions.canDeleteTargets)
    readyStore.isSessionActionInFlight = false

    let readOnlyStore = HarnessMonitorPreviewStoreFactory.makeStore(for: .empty)
    let readOnlyActions = TaskBoardOverviewActions(store: readOnlyStore, scope: .dashboard)
    #expect(!readOnlyActions.canDeleteItem)
    #expect(!readOnlyActions.canDeleteTargets)

    let missingClientStore = HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded)
    missingClientStore.client = nil
    let missingClientActions = TaskBoardOverviewActions(
      store: missingClientStore,
      scope: .dashboard
    )
    #expect(!missingClientActions.canDeleteItem)
    #expect(!missingClientActions.canDeleteTargets)
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

  @Test("Rejected card move reports that the board changed")
  func rejectedCardMoveReportsBoardChange() {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .empty)
    let actions = TaskBoardOverviewActions(store: store, scope: .dashboard)
    let dragItem = TaskBoardCardDragItem.inbox(
      sessionID: "session-a",
      taskID: "task-a",
      status: .open,
      sourceLaneRawValue: TaskBoardInboxLane.backlog.rawValue
    )

    #expect(
      !actions.moveCardsOrReportRejection(
        [dragItem],
        to: .inProgress,
        liveInboxItems: TaskBoardLiveInboxItems()
      )
    )
    #expect(store.toast.activeFeedback.last?.severity == .failure)
    #expect(
      store.toast.activeFeedback.last?.message
        == "Cannot move task: the board changed before the move completed"
    )
  }

  @Test("Report drop rejection stays inert with no store")
  func reportDropRejectionStaysInertWithNoStore() {
    let actions = TaskBoardOverviewActions(store: nil, scope: .dashboard)

    actions.reportDropRejection("Cannot move task: an action is already in progress")
  }

  private static func makeAPIItem(
    id: String,
    status: TaskBoardStatus,
    kind: TaskBoardItemKind = .task
  ) -> TaskBoardItem {
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
      kind: kind,
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

  private static func makeWorkItem(
    taskId: String,
    status: TaskStatus,
    assignedTo: String? = nil
  ) -> WorkItem {
    WorkItem(
      taskId: taskId,
      title: "Fixture task",
      context: "fixture",
      severity: .medium,
      status: status,
      assignedTo: assignedTo,
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

  private static func makeLiveInboxItems(
    sessionID: String,
    task: WorkItem
  ) -> TaskBoardLiveInboxItems {
    let detail = makeSessionDetail(sessionID: sessionID, tasks: [task])
    guard let item = TaskBoardInboxItem(session: detail.session, task: task) else {
      fatalError("Expected an open task-board inbox fixture")
    }
    let liveInboxItems = TaskBoardLiveInboxItems()
    liveInboxItems.replace(
      with: [.inbox(sessionID: sessionID, taskID: task.taskId): item]
    )
    return liveInboxItems
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
