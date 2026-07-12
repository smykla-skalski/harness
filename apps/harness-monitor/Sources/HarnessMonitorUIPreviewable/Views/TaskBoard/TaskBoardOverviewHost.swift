import HarnessMonitorIntents
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

  init(
    scope: Scope,
    store: HarnessMonitorStore,
    snapshot: TaskBoardInboxSnapshot,
    taskBoardItems: [TaskBoardItem],
    decisions: [Decision],
    orchestratorStatus: TaskBoardOrchestratorStatus?,
    evaluationSummary: TaskBoardEvaluationSummary?,
    isActionInFlight: Bool
  ) {
    self.scope = scope
    self.store = store
    self.snapshot = snapshot
    self.taskBoardItems = taskBoardItems
    self.decisions = decisions
    self.orchestratorStatus = orchestratorStatus
    self.evaluationSummary = evaluationSummary
    self.isActionInFlight = isActionInFlight
  }

  var body: some View {
    TaskBoardOverviewView(
      snapshot: snapshot,
      taskBoardItems: taskBoardItems,
      store: store,
      orchestratorStatus: orchestratorStatus,
      evaluationSummary: evaluationSummary,
      taskBoardSessionID: scope.sessionID,
      contentHorizontalPadding: scope.taskBoardContentHorizontalPadding,
      fillsAvailableHeight: scope.fillsAvailableHeight,
      decisions: decisions,
      isActionInFlight: isActionInFlight,
      onOpenItem: openInboxItem,
      onOpenTaskBoardItem: openTaskBoardItem,
      onMoveInboxItems: moveInboxItems,
      onMoveTaskBoardItems: moveTaskBoardItems,
      onOpenDecision: openDecision,
      onCreateTaskBoardItem: createTaskBoardItem,
      onUpdateTaskBoardItem: updateTaskBoardItem,
      onDeleteTaskBoardItem: deleteTaskBoardItem,
      onDeleteTaskBoardTargets: deleteTaskBoardTargets,
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

  private func moveTaskBoardItems(_ updates: [TaskBoardItemStatusUpdate]) {
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Moving task board items") {
        await store.updateTaskBoardItemStatuses(updates)
      }
    )
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
    deleteTaskBoardTargets([TaskBoardDeletionTarget(taskBoardItem: item)])
  }

  private func deleteTaskBoardTargets(_ targets: [TaskBoardDeletionTarget]) {
    store.requestTaskBoardDeletionConfirmation(targets: targets)
  }

  private func moveInboxItems(_ updates: [TaskBoardInboxStatusUpdate]) {
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Moving session tasks") {
        await store.updateTaskBoardInboxStatuses(updates)
      }
    )
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
    HarnessMonitorIntentDonations.donateApprovePlan(items: [item])
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

extension TaskBoardOverviewHost.Scope {
  fileprivate var sessionID: String? {
    switch self {
    case .dashboard:
      nil
    case .session(let sessionID):
      sessionID
    }
  }

  fileprivate var taskBoardContentHorizontalPadding: CGFloat {
    switch self {
    case .dashboard:
      24
    case .session:
      0
    }
  }

  fileprivate var fillsAvailableHeight: Bool {
    switch self {
    case .dashboard:
      true
    case .session:
      false
    }
  }
}
