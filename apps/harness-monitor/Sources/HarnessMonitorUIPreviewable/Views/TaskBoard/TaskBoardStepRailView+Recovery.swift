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

  /// The item this session's Pick loaded, or the one a restored pick named. A
  /// launch cannot hand over its dispatch plan, so the restored half is an
  /// identity plus the prompt the user had already read.
  var pickedItemID: String? {
    if let pickedItemID = stepRailState.pickedSelection?.item.id { return pickedItemID }
    return stepRailState.restoredPickedPrompt == nil ? nil : stepRailState.lockedItemID
  }

  /// The prompt the Deliver step previews: this session's pick, then the plan
  /// the daemon still holds for the item, then the restored pick's.
  var activePrompt: String? {
    guard let item = activeItem else { return nil }
    if let picked = stepRailState.pickedSelection, picked.item.id == item.id {
      return picked.plan.renderedPrompt
    }
    if let plan = stepFlow.dispatchPlan { return plan.renderedPrompt }
    return item.id == pickedItemID ? stepRailState.restoredPickedPrompt : nil
  }

  var deliveryItemID: String? {
    stepFlow.deliveryItemID(
      pickedItemID: pickedItemID,
      heldDispatches: status.heldDispatches
    )
  }

  var stagePlan: TaskBoardStepStagePlan {
    TaskBoardStepStageResolver.plan(
      for: TaskBoardStepStageInputs(
        item: activeItem,
        latestRecord: stepFlow.latestRecord,
        hasPicked: stepFlow.hasPicked || (pickedItemID != nil && pickedItemID == activeItem?.id),
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
