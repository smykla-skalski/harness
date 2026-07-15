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
  let showsOperationsPanel: Bool
  let isCommandFocusActive: Bool
  let operationsInspectorFocus: TaskBoardOperationsInspectorFocus?

  init(
    scope: Scope,
    store: HarnessMonitorStore,
    snapshot: TaskBoardInboxSnapshot,
    taskBoardItems: [TaskBoardItem],
    decisions: [Decision],
    orchestratorStatus: TaskBoardOrchestratorStatus?,
    evaluationSummary: TaskBoardEvaluationSummary?,
    isActionInFlight: Bool,
    showsOperationsPanel: Bool = true,
    isCommandFocusActive: Bool = true,
    operationsInspectorFocus: TaskBoardOperationsInspectorFocus? = nil
  ) {
    self.scope = scope
    self.store = store
    self.snapshot = snapshot
    self.taskBoardItems = taskBoardItems
    self.decisions = decisions
    self.orchestratorStatus = orchestratorStatus
    self.evaluationSummary = evaluationSummary
    self.isActionInFlight = isActionInFlight
    self.showsOperationsPanel = showsOperationsPanel
    self.isCommandFocusActive = isCommandFocusActive
    self.operationsInspectorFocus = operationsInspectorFocus
  }

  var body: some View {
    overviewView
  }

  private var overviewView: TaskBoardOverviewView {
    let dashboardCreateItem: ((TaskBoardCreateItemRequest, TaskBoardStatus) -> Void)? =
      scope.isDashboard
      ? { request, status in createTaskBoardItem(request, initialStatus: status) }
      : nil
    let dashboardEvaluate: (() -> Void)? = scope.isDashboard ? { evaluateTaskBoard() } : nil
    let dashboardRefresh: (() -> Void)? = scope.isDashboard ? { refreshTaskBoard() } : nil
    let dashboardStart: (() -> Void)? = scope.isDashboard ? { startTaskBoardOrchestrator() } : nil
    let dashboardStop: (() -> Void)? = scope.isDashboard ? { stopTaskBoardOrchestrator() } : nil
    let dashboardStepMode: (@MainActor @Sendable (Bool) -> Void)?
    if scope.isDashboard {
      let stepModeAction: @MainActor @Sendable (Bool) -> Void = { enabled in
        setTaskBoardStepMode(enabled)
      }
      dashboardStepMode = stepModeAction
    } else {
      dashboardStepMode = nil
    }

    return TaskBoardOverviewView(
      snapshot: snapshot,
      taskBoardItems: taskBoardItems,
      store: store,
      orchestratorStatus: orchestratorStatus,
      evaluationSummary: scope.isDashboard ? evaluationSummary : nil,
      taskBoardSessionID: scope.sessionID,
      contentHorizontalPadding: scope.taskBoardContentHorizontalPadding,
      fillsAvailableHeight: scope.fillsAvailableHeight,
      showsOperationsPanel: scope.isDashboard && showsOperationsPanel,
      isCommandFocusActive: isCommandFocusActive,
      operationsInspectorFocus: operationsInspectorFocus,
      decisions: decisions,
      isActionInFlight: isActionInFlight,
      onOpenItem: openInboxItem,
      onOpenTaskBoardItem: openTaskBoardItem,
      onMoveInboxItems: moveInboxItems,
      onMoveTaskBoardItems: moveTaskBoardItems,
      onOpenDecision: openDecision,
      onCreateTaskBoardItem: dashboardCreateItem,
      onUpdateTaskBoardItem: updateTaskBoardItem,
      onDeleteTaskBoardItem: deleteTaskBoardItem,
      onDeleteTaskBoardTargets: deleteTaskBoardTargets,
      onEvaluateTaskBoard: dashboardEvaluate,
      onEvaluateTaskBoardItem: evaluateTaskBoardItem,
      onBeginTaskBoardPlan: beginTaskBoardPlan,
      onSubmitTaskBoardPlan: submitTaskBoardPlan,
      onApproveTaskBoardPlan: approveTaskBoardPlan,
      onRevokeTaskBoardPlan: revokeTaskBoardPlan,
      onRefreshTaskBoard: dashboardRefresh,
      onStartTaskBoardOrchestrator: dashboardStart,
      onStopTaskBoardOrchestrator: dashboardStop,
      onRunTaskBoardOrchestratorOnce: runTaskBoardOrchestratorOnce,
      onSetTaskBoardStepMode: dashboardStepMode,
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
      guard item.sessionId == sessionID, let workItemID = item.workItemId else {
        return
      }
      store.presentedSheet = .taskActions(
        sessionID: sessionID,
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
    case .session(let sessionID):
      guard item.session.sessionId == sessionID else {
        return
      }
      store.presentedSheet = .taskActions(
        sessionID: sessionID,
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
      guard decision.sessionID == sessionID else {
        return
      }
      store.requestSessionRoute(
        .decision(
          sessionID: sessionID,
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
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Creating task board item") {
        await store.createTaskBoardItem(request: request, initialStatus: initialStatus)
      }
    )
  }

  private func updateTaskBoardItem(_ itemID: String, request: TaskBoardUpdateItemRequest) {
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Updating task board item") {
        await store.updateTaskBoardItem(id: itemID, request: request)
      }
    )
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
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Evaluating task board") {
        await store.evaluateTaskBoard()
      }
    )
  }

  private func evaluateTaskBoardItem(_ item: TaskBoardItem) {
    let request = TaskBoardOverviewItemBehavior.evaluationRequest(for: item)
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Evaluating task board item") {
        await store.evaluateTaskBoard(request: request)
      }
    )
  }

  private func beginTaskBoardPlan(_ item: TaskBoardItem) {
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Beginning task board plan") {
        await store.beginTaskBoardPlan(id: item.id)
      }
    )
  }

  private func submitTaskBoardPlan(_ item: TaskBoardItem, summary: String) {
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Submitting task board plan") {
        await store.submitTaskBoardPlan(id: item.id, summary: summary)
      }
    )
  }

  private func approveTaskBoardPlan(
    _ item: TaskBoardItem,
    approvedBy: String,
    approvedAt: String?
  ) {
    HarnessMonitorIntentDonations.donateApprovePlan(items: [item])
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Approving task board plan") {
        await store.approveTaskBoardPlan(
          id: item.id,
          approvedBy: approvedBy,
          approvedAt: approvedAt
        )
      }
    )
  }

  private func revokeTaskBoardPlan(_ item: TaskBoardItem) {
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Revoking task board plan") {
        await store.revokeTaskBoardPlan(id: item.id)
      }
    )
  }

  private func refreshTaskBoard() {
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Syncing task board") {
        await store.refreshTaskBoardDashboard()
      }
    )
  }

  private func startTaskBoardOrchestrator() {
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Starting task board orchestrator") {
        await store.startTaskBoardOrchestrator()
      }
    )
  }

  private func stopTaskBoardOrchestrator() {
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Stopping task board orchestrator") {
        await store.stopTaskBoardOrchestrator()
      }
    )
  }

  private func runTaskBoardOrchestratorOnce(_ request: TaskBoardOrchestratorRunOnceRequest) {
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(
        title: request.dryRun == true ? "Previewing task board run" : "Running task board once"
      ) {
        await store.runTaskBoardOrchestratorOnce(request: request)
      }
    )
  }

  private func setTaskBoardStepMode(_ enabled: Bool) {
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: enabled ? "Enabling task-board step mode" : "Disabling task-board step mode") {
        await store.setTaskBoardStepMode(enabled: enabled)
      }
    )
  }
}

extension TaskBoardOverviewHost.Scope {
  fileprivate var isDashboard: Bool {
    self == .dashboard
  }

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
