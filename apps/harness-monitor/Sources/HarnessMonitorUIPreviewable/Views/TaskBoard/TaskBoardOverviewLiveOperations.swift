import HarnessMonitorKit
import SwiftUI

enum TaskBoardOverviewLiveOperation {
  case evaluateBoard
  case start(TaskBoardAutomationSchedulingSettings)
  case runOnce(TaskBoardOrchestratorRunOnceRequest)

  var title: String {
    switch self {
    case .evaluateBoard:
      "Evaluate the live task board?"
    case .start:
      "Start live automation?"
    case .runOnce:
      "Run the task board live?"
    }
  }

  var actionTitle: String {
    switch self {
    case .evaluateBoard:
      "Evaluate Live"
    case .start:
      "Start Live"
    case .runOnce:
      "Run Once Live"
    }
  }

  var message: String {
    switch self {
    case .evaluateBoard:
      "This evaluates the board and applies any resulting item transitions"
    case .start(let scheduling):
      """
      Continuously syncs configured repositories and dispatches at most \
      \(scheduling.maxDispatchesPerRun) per run, with at most \
      \(scheduling.maxConcurrentWorkflows) workflows active. Stop prevents later dispatches; \
      workflows already started continue until cancelled separately
      """
    case .runOnce:
      "This runs a live orchestrator tick, which can dispatch work and update board items"
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

  func requestLiveBoardEvaluation() {
    guard actions.canEvaluateBoard else { return }
    evaluatePreviewSummaryValue = nil
    pendingLiveOperationValue = .evaluateBoard
  }

  func requestTaskBoardItemEvaluation(_ item: TaskBoardItem) {
    selectionModelValue.selectedItemID = item.id
    actions.evaluateTaskBoardItemOrPreview(
      item,
      dryRun: evaluateDryRun,
      previewState: evaluatePreviewStateValue
    )
  }

  func requestRunOnce(_ request: TaskBoardOrchestratorRunOnceRequest) {
    guard actions.canRunOrchestratorOnce else { return }
    guard request.dryRun != true else {
      actions.runTaskBoardOrchestratorOnce(request)
      return
    }
    pendingLiveOperationValue = .runOnce(request)
  }

  func performLiveOperation(_ operation: TaskBoardOverviewLiveOperation) {
    switch operation {
    case .evaluateBoard:
      actions.evaluateTaskBoard()
    case .start:
      actions.startTaskBoardOrchestrator()
    case .runOnce(let request):
      actions.runTaskBoardOrchestratorOnce(request)
    }
  }
}
