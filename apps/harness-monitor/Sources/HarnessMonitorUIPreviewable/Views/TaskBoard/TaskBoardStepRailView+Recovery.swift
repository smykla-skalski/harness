import HarnessMonitorKit

extension TaskBoardStepRailView {
  var stepFlow: TaskBoardStepRecoveredFlow {
    let state = stepRailState
    return TaskBoardStepFlowRecoveryResolver.resolve(
      TaskBoardStepFlowRecoveryInputs(
        lockedItemID: state.lockedItemID,
        pickedSelection: state.pickedSelection,
        delivery: state.delivery,
        targetItem: targetItem,
        taskBoardItems: taskBoardItems,
        heldDispatches: status.heldDispatches,
        latestEvaluation: latestEvaluation,
        latestEvaluationBaselineRunID: store.contentUI.dashboard
          .taskBoardEvaluationBaselineRunID,
        recentDispatch: store.contentUI.dashboard.taskBoardDispatchSummary,
        lastRun: status.lastRun
      )
    )
  }

  var activeItem: TaskBoardItem? { stepFlow.item }

  var activeSelection: TaskBoardDispatchSelection? {
    guard let item = activeItem else { return nil }
    if stepRailState.pickedSelection?.item.id == item.id {
      return stepRailState.pickedSelection
    }
    return stepFlow.dispatchPlan.map { TaskBoardDispatchSelection(item: item, plan: $0) }
  }

  var deliveryItemID: String? {
    stepFlow.deliveryItemID(
      pickedSelection: stepRailState.pickedSelection,
      heldDispatches: status.heldDispatches
    )
  }

  var stagePlan: TaskBoardStepStagePlan {
    TaskBoardStepStageResolver.plan(
      for: TaskBoardStepStageInputs(
        item: activeItem,
        latestRecord: stepFlow.latestRecord,
        hasPicked: stepFlow.hasPicked,
        hasDelivered: stepRailState.delivery != nil,
        canDeliver: deliveryItemID != nil
      )
    )
  }

  var cardPresentation: TaskBoardStepCardPresentation {
    TaskBoardStepCardPresentation.resolve(
      plan: stagePlan,
      viewingColumn: stepRailState.viewingColumn
    )
  }

  var cardIdentity: String {
    switch cardPresentation {
    case .empty:
      "empty"
    case .preview(let column):
      "preview-\(column.rawValue)"
    case .live(let stage):
      "live-\(stage.rawValue)"
    }
  }
}
