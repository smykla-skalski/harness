import HarnessMonitorIntents
import HarnessMonitorKit
import SwiftUI

extension TaskBoardOverviewActions {
  // MARK: - Item lifecycle

  func createTaskBoardItem(
    _ request: TaskBoardCreateItemRequest,
    outcome: TaskBoardItemCreationOutcome
  ) {
    guard canCreateItem, let store else { return }
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Creating task board item") {
        let success = await store.createTaskBoardItem(request: request)
        guard success else { return }
        await MainActor.run {
          outcome.succeeded = true
        }
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
