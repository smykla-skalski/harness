import HarnessMonitorKit
import SwiftUI

struct TaskBoardOverviewHost: View {
  enum Scope: Equatable {
    case dashboard
    case session(sessionID: String)
  }

  let scope: Scope
  let store: HarnessMonitorStore
  let snapshot: TaskBoardInboxSnapshot
  let taskBoardItems: [TaskBoardItem]
  let decisions: [Decision]
  let orchestratorStatus: TaskBoardOrchestratorStatus?
  let evaluationSummary: TaskBoardEvaluationSummary?
  let isActionInFlight: Bool

  var body: some View {
    TaskBoardOverviewView(
      snapshot: snapshot,
      taskBoardItems: taskBoardItems,
      store: store,
      orchestratorStatus: orchestratorStatus,
      evaluationSummary: evaluationSummary,
      taskBoardSessionID: scope.sessionID,
      contentHorizontalPadding: scope.taskBoardContentHorizontalPadding,
      decisions: decisions,
      isActionInFlight: isActionInFlight,
      onOpenItem: openInboxItem,
      onOpenTaskBoardItem: openTaskBoardItem,
      onMoveInboxItem: moveInboxItem,
      onMoveTaskBoardItem: moveTaskBoardItem,
      onOpenDecision: openDecision,
      onCreateTaskBoardItem: createTaskBoardItem,
      onUpdateTaskBoardItem: updateTaskBoardItem,
      onDeleteTaskBoardItem: deleteTaskBoardItem,
      onEvaluateTaskBoard: evaluateTaskBoard,
      onEvaluateTaskBoardItem: evaluateTaskBoardItem,
      onBeginTaskBoardPlan: beginTaskBoardPlan,
      onSubmitTaskBoardPlan: submitTaskBoardPlan,
      onApproveTaskBoardPlan: approveTaskBoardPlan,
      onRefreshTaskBoard: refreshTaskBoard,
      onStartTaskBoardOrchestrator: startTaskBoardOrchestrator,
      onStopTaskBoardOrchestrator: stopTaskBoardOrchestrator,
      onRunTaskBoardOrchestratorOnce: runTaskBoardOrchestratorOnce,
      decisionItems: store.supervisorOpenDecisionPresentationItems,
      decisionsByID: store.supervisorOpenDecisionsByID
    )
  }
  private func openTaskBoardItem(_ item: TaskBoardItem) {
    switch scope {
    case .dashboard:
      guard
        let sessionID = item.sessionId,
        let workItemID = item.workItemId
      else {
        return
      }
      Task { @MainActor in
        await store.selectSession(sessionID)
        store.presentedSheet = .taskActions(sessionID: sessionID, taskID: workItemID)
      }
    case .session(let sessionID):
      guard let workItemID = item.workItemId else {
        return
      }
      store.presentedSheet = .taskActions(
        sessionID: item.sessionId ?? sessionID,
        taskID: workItemID
      )
    }
  }

  private func openInboxItem(_ item: TaskBoardInboxItem) {
    switch scope {
    case .dashboard:
      Task { @MainActor in
        await store.selectSession(item.session.sessionId)
        store.presentedSheet = .taskActions(
          sessionID: item.session.sessionId,
          taskID: item.task.taskId
        )
      }
    case .session:
      store.presentedSheet = .taskActions(
        sessionID: item.session.sessionId,
        taskID: item.task.taskId
      )
    }
  }

  private func openDecision(_ decision: Decision) {
    store.supervisorSelectedDecisionID = decision.id
    switch scope {
    case .dashboard:
      guard let sessionID = decision.sessionID else {
        return
      }
      Task { @MainActor in
        await store.selectSession(sessionID)
      }
    case .session(let sessionID):
      store.requestSessionRoute(
        .decision(
          sessionID: decision.sessionID ?? sessionID,
          decisionID: decision.id
        ),
        resetDecisionFilters: true
      )
    }
  }

  private func moveTaskBoardItem(_ itemID: String, status: TaskBoardStatus) {
    Task { @MainActor in
      await store.updateTaskBoardItemStatus(id: itemID, status: status)
    }
  }

  private func createTaskBoardItem(
    _ request: TaskBoardCreateItemRequest,
    initialStatus: TaskBoardStatus
  ) {
    Task { @MainActor in
      await store.createTaskBoardItem(request: request, initialStatus: initialStatus)
    }
  }

  private func updateTaskBoardItem(_ itemID: String, request: TaskBoardUpdateItemRequest) {
    Task { @MainActor in
      await store.updateTaskBoardItem(id: itemID, request: request)
    }
  }

  private func deleteTaskBoardItem(_ item: TaskBoardItem) {
    Task { @MainActor in
      await store.deleteTaskBoardItem(id: item.id)
    }
  }

  private func moveInboxItem(_ item: TaskBoardInboxItem, status: TaskStatus) {
    Task { @MainActor in
      await store.updateTaskStatus(
        taskID: item.task.taskId,
        status: status,
        sessionID: item.session.sessionId
      )
    }
  }

  private func evaluateTaskBoard() {
    Task { @MainActor in
      await store.evaluateTaskBoard()
    }
  }

  private func evaluateTaskBoardItem(_ item: TaskBoardItem) {
    let request = TaskBoardOverviewItemBehavior.evaluationRequest(for: item)
    Task { @MainActor in
      await store.evaluateTaskBoard(request: request)
    }
  }

  private func beginTaskBoardPlan(_ item: TaskBoardItem) {
    Task { @MainActor in
      await store.beginTaskBoardPlan(id: item.id)
    }
  }

  private func submitTaskBoardPlan(_ item: TaskBoardItem, summary: String) {
    Task { @MainActor in
      await store.submitTaskBoardPlan(id: item.id, summary: summary)
    }
  }

  private func approveTaskBoardPlan(
    _ item: TaskBoardItem,
    approvedBy: String,
    approvedAt: String?
  ) {
    Task { @MainActor in
      await store.approveTaskBoardPlan(
        id: item.id,
        approvedBy: approvedBy,
        approvedAt: approvedAt
      )
    }
  }

  private func refreshTaskBoard() {
    Task { @MainActor in
      await store.refreshTaskBoardDashboard()
    }
  }

  private func startTaskBoardOrchestrator() {
    Task { @MainActor in
      await store.startTaskBoardOrchestrator()
    }
  }

  private func stopTaskBoardOrchestrator() {
    Task { @MainActor in
      await store.stopTaskBoardOrchestrator()
    }
  }

  private func runTaskBoardOrchestratorOnce(_ request: TaskBoardOrchestratorRunOnceRequest) {
    Task { @MainActor in
      await store.runTaskBoardOrchestratorOnce(request: request)
    }
  }
}

private extension TaskBoardOverviewHost.Scope {
  var sessionID: String? {
    switch self {
    case .dashboard:
      nil
    case .session(let sessionID):
      sessionID
    }
  }

  var taskBoardContentHorizontalPadding: CGFloat {
    switch self {
    case .dashboard:
      24
    case .session:
      0
    }
  }
}
