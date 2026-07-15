import HarnessMonitorKit
import SwiftUI

enum TaskBoardOverviewLiveOperation {
  case sync
  case evaluateBoard
  case runOnce(TaskBoardOrchestratorRunOnceRequest)

  var title: String {
    switch self {
    case .sync:
      "Sync the live task board?"
    case .evaluateBoard:
      "Evaluate the live task board?"
    case .runOnce:
      "Run the task board live?"
    }
  }

  var actionTitle: String {
    switch self {
    case .sync:
      "Sync Live"
    case .evaluateBoard:
      "Evaluate Live"
    case .runOnce:
      "Run Once Live"
    }
  }

  var message: String {
    switch self {
    case .sync:
      "This pulls external task sources and applies changes to the live board."
    case .evaluateBoard:
      "This evaluates the board and applies any resulting item transitions."
    case .runOnce:
      "This runs a live orchestrator tick, which can dispatch work and update board items."
    }
  }
}

extension TaskBoardOverviewView {
  var pendingLiveOperationIsPresented: Binding<Bool> {
    Binding(
      get: { pendingLiveOperationValue != nil },
      set: { if !$0 { pendingLiveOperationValue = nil } }
    )
  }

  var runOnceDryRun: Bool {
    orchestratorStatus?.settings.dryRunDefault ?? true
  }

  func requestTaskBoardSync() {
    guard onRefreshTaskBoard != nil else { return }
    pendingLiveOperationValue = .sync
  }

  func requestLiveBoardEvaluation() {
    guard onEvaluateTaskBoard != nil else { return }
    evaluatePreviewSummaryValue = nil
    pendingLiveOperationValue = .evaluateBoard
  }

  func requestTaskBoardItemEvaluation(_ item: TaskBoardItem) {
    selectedTaskBoardItemIDValue = item.id
    guard !evaluateDryRun else {
      enqueueTaskBoardItemEvaluationPreview(item)
      return
    }
    guard onEvaluateTaskBoardItem != nil || onEvaluateTaskBoard != nil else { return }
    if let onEvaluateTaskBoardItem {
      onEvaluateTaskBoardItem(item)
    } else {
      onEvaluateTaskBoard?()
    }
  }

  func requestRunOnce(_ request: TaskBoardOrchestratorRunOnceRequest) {
    guard onRunTaskBoardOrchestratorOnce != nil else { return }
    guard request.dryRun != true else {
      onRunTaskBoardOrchestratorOnce?(request)
      return
    }
    pendingLiveOperationValue = .runOnce(request)
  }

  func performLiveOperation(_ operation: TaskBoardOverviewLiveOperation) {
    switch operation {
    case .sync:
      onRefreshTaskBoard?()
    case .evaluateBoard:
      onEvaluateTaskBoard?()
    case .runOnce(let request):
      onRunTaskBoardOrchestratorOnce?(request)
    }
  }

  private func enqueueTaskBoardItemEvaluationPreview(_ item: TaskBoardItem) {
    guard let store else { return }
    let previewState = evaluatePreviewStateValue
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Previewing task-board item evaluate") {
        let summary = await store.previewEvaluateTaskBoard(status: item.status, itemID: item.id)
        await MainActor.run {
          previewState.summary = summary
        }
      }
    )
  }
}
