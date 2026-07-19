import HarnessMonitorIntents
import HarnessMonitorKit
import SwiftUI

/// Hand-rolled `Equatable` (store identity + scope only) so views holding
/// this as a stored prop stay diffable instead of always comparing unequal.
/// `public` because `TaskBoardOverviewView.init` (public) takes one as a
/// defaulted parameter.
public struct TaskBoardOverviewActions: Equatable {
  public enum Scope: Equatable {
    case dashboard
    case session(sessionID: String)
  }

  let store: HarnessMonitorStore?
  let scope: Scope

  public init(store: HarnessMonitorStore?, scope: Scope) {
    self.store = store
    self.scope = scope
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.store === rhs.store && lhs.scope == rhs.scope
  }

  var isDashboardScope: Bool {
    scope == .dashboard
  }

  var sessionID: String? {
    switch scope {
    case .dashboard:
      nil
    case .session(let sessionID):
      sessionID
    }
  }

  private var hasStore: Bool {
    store != nil
  }

  // MARK: - Capabilities

  var canCreateItem: Bool { hasStore && isDashboardScope }
  var canEvaluateBoard: Bool { hasStore && isDashboardScope }
  var canRefreshBoard: Bool { hasStore && isDashboardScope }
  var canStartOrchestrator: Bool { hasStore && isDashboardScope }
  var canStopOrchestrator: Bool { hasStore && isDashboardScope }
  var canSetStepMode: Bool { hasStore && isDashboardScope }

  var canMoveInboxItems: Bool { hasStore }
  var canMoveTaskBoardItems: Bool { hasStore }
  var canUpdateItem: Bool { hasStore }
  var canDeleteItem: Bool { hasStore }
  var canDeleteTargets: Bool { hasStore }
  var canEvaluateItem: Bool { hasStore }
  var canBeginPlan: Bool { hasStore }
  var canSubmitPlan: Bool { hasStore }
  var canApprovePlan: Bool { hasStore }
  var canRevokePlan: Bool { hasStore }
  var canRunOrchestratorOnce: Bool { hasStore }

  // MARK: - Navigation

  @MainActor
  func openTaskBoardItem(_ item: TaskBoardItem) {
    guard let store else { return }
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
      store.presentedSheet = .taskActions(sessionID: sessionID, taskID: workItemID)
    }
  }

  @MainActor
  func openInboxItem(_ item: TaskBoardInboxItem) {
    guard let store else { return }
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

  @MainActor
  func openDecision(_ decision: Decision) {
    guard let store else { return }
    store.supervisorSelectedDecisionID = decision.id
    switch scope {
    case .dashboard:
      guard let sessionID = decision.sessionID else { return }
      Task { @MainActor in
        await store.selectSession(sessionID)
      }
    case .session(let sessionID):
      guard decision.sessionID == sessionID else { return }
      store.requestSessionRoute(
        .decision(sessionID: sessionID, decisionID: decision.id),
        resetDecisionFilters: true
      )
    }
  }

  // MARK: - Card moves

  /// Items come pre-validated from `TaskBoardCardDropPlan.resolve`, so this
  /// needs no fresh `TaskBoardOverviewPresentation` lookup.
  @discardableResult
  func moveCards(_ items: [TaskBoardCardDragItem], to lane: TaskBoardInboxLane) -> Bool {
    guard hasStore else { return false }
    var taskBoardUpdates: [TaskBoardItemStatusUpdate] = []
    var inboxUpdates: [TaskBoardInboxStatusUpdate] = []
    for item in items {
      guard item.accepts(destination: lane) else { return false }
      switch item {
      case .api(let itemID, _):
        taskBoardUpdates.append(
          TaskBoardItemStatusUpdate(id: itemID, status: lane.taskBoardDropStatus)
        )
      case .inbox(let sessionID, let taskID, _, _):
        guard let destinationStatus = lane.taskDropStatus else { return false }
        inboxUpdates.append(
          TaskBoardInboxStatusUpdate(sessionID: sessionID, taskID: taskID, status: destinationStatus)
        )
      }
    }
    guard !taskBoardUpdates.isEmpty || !inboxUpdates.isEmpty else { return false }
    if !taskBoardUpdates.isEmpty {
      moveTaskBoardItems(taskBoardUpdates)
    }
    if !inboxUpdates.isEmpty {
      moveInboxItems(inboxUpdates)
    }
    return true
  }

  func moveTaskBoardItems(_ updates: [TaskBoardItemStatusUpdate]) {
    guard let store else { return }
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Moving task board items") {
        await store.updateTaskBoardItemStatuses(updates)
      }
    )
  }

  func moveInboxItems(_ updates: [TaskBoardInboxStatusUpdate]) {
    guard let store else { return }
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Moving session tasks") {
        await store.updateTaskBoardInboxStatuses(updates)
      }
    )
  }

  // MARK: - Item lifecycle

  func createTaskBoardItem(_ request: TaskBoardCreateItemRequest, initialStatus: TaskBoardStatus) {
    guard canCreateItem, let store else { return }
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Creating task board item") {
        await store.createTaskBoardItem(request: request, initialStatus: initialStatus)
      }
    )
  }

  func updateTaskBoardItem(_ itemID: String, request: TaskBoardUpdateItemRequest) {
    guard let store else { return }
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Updating task board item") {
        await store.updateTaskBoardItem(id: itemID, request: request)
      }
    )
  }

  @MainActor
  func deleteTaskBoardItem(_ item: TaskBoardItem) {
    deleteTaskBoardTargets([TaskBoardDeletionTarget(taskBoardItem: item)])
  }

  @MainActor
  func deleteTaskBoardTargets(_ targets: [TaskBoardDeletionTarget]) {
    store?.requestTaskBoardDeletionConfirmation(targets: targets)
  }

  // MARK: - Evaluate

  func evaluateTaskBoard() {
    guard canEvaluateBoard, let store else { return }
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Evaluating task board") {
        await store.evaluateTaskBoard()
      }
    )
  }

  func evaluateTaskBoardItem(_ item: TaskBoardItem) {
    guard let store else { return }
    let request = TaskBoardOverviewItemBehavior.evaluationRequest(for: item)
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Evaluating task board item") {
        await store.evaluateTaskBoard(request: request)
      }
    )
  }

  func evaluateTaskBoardItemOrPreview(
    _ item: TaskBoardItem,
    dryRun: Bool,
    previewState: TaskBoardEvaluatePreviewState
  ) {
    guard dryRun else {
      if canEvaluateItem {
        evaluateTaskBoardItem(item)
      } else {
        evaluateTaskBoard()
      }
      return
    }
    guard let store else { return }
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Previewing task-board item evaluate") {
        let summary = await store.previewEvaluateTaskBoard(status: item.status, itemID: item.id)
        await MainActor.run {
          previewState.summary = summary
        }
      }
    )
  }

  // MARK: - Plan lifecycle

  func beginTaskBoardPlan(_ item: TaskBoardItem) {
    guard let store else { return }
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Beginning task board plan") {
        await store.beginTaskBoardPlan(id: item.id)
      }
    )
  }

  func submitTaskBoardPlan(_ item: TaskBoardItem, summary: String) {
    guard let store else { return }
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Submitting task board plan") {
        await store.submitTaskBoardPlan(id: item.id, summary: summary)
      }
    )
  }

  func approveTaskBoardPlan(_ item: TaskBoardItem, approvedBy: String, approvedAt: String?) {
    guard let store else { return }
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

  func revokeTaskBoardPlan(_ item: TaskBoardItem) {
    guard let store else { return }
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Revoking task board plan") {
        await store.revokeTaskBoardPlan(id: item.id)
      }
    )
  }

  // MARK: - Sync / orchestrator

  func refreshTaskBoard() {
    guard canRefreshBoard, let store else { return }
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Syncing task board") {
        await store.refreshTaskBoardDashboard()
      }
    )
  }

  func startTaskBoardOrchestrator() {
    guard canStartOrchestrator, let store else { return }
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Starting task board orchestrator") {
        await store.startTaskBoardOrchestrator()
      }
    )
  }

  func stopTaskBoardOrchestrator() {
    guard canStopOrchestrator, let store else { return }
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Stopping task board orchestrator") {
        await store.stopTaskBoardOrchestrator()
      }
    )
  }

  func runTaskBoardOrchestratorOnce(_ request: TaskBoardOrchestratorRunOnceRequest) {
    guard let store else { return }
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(
        title: request.dryRun == true ? "Previewing task board run" : "Running task board once"
      ) {
        await store.runTaskBoardOrchestratorOnce(request: request)
      }
    )
  }

  func setTaskBoardStepMode(_ enabled: Bool) {
    guard canSetStepMode, let store else { return }
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: enabled ? "Enabling task-board step mode" : "Disabling task-board step mode") {
        await store.setTaskBoardStepMode(enabled: enabled)
      }
    )
  }
}
