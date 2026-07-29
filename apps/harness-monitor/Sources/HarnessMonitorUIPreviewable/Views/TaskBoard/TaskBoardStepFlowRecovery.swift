import HarnessMonitorKit

struct TaskBoardStepRecoveredFlow: Equatable, Sendable {
  enum Source: Equatable, Sendable {
    case explicit
    case heldDispatch
    case needsEvaluation
    case target
    case none
  }

  let item: TaskBoardItem?
  let latestRecord: TaskBoardEvaluationRecord?
  let dispatchPlan: TaskBoardDispatchPlan?
  let source: Source
  let hasPicked: Bool

  func deliveryItemID(
    pickedItemID: String?,
    heldDispatches: TaskBoardHeldDispatchSummary
  ) -> String? {
    guard let itemID = item?.id else { return nil }
    let wasPicked = pickedItemID == itemID
    let isHeld = heldDispatches.items.contains { $0.boardItemId == itemID }
    return wasPicked || isHeld ? itemID : nil
  }
}

struct TaskBoardStepFlowRecoveryInputs {
  let lockedItemID: String?
  let pickedSelection: TaskBoardDispatchSelection?
  let delivery: TaskBoardDispatchDelivery?
  let targetItem: TaskBoardItem?
  let taskBoardItems: [TaskBoardItem]
  let heldDispatches: TaskBoardHeldDispatchSummary
  let latestEvaluation: TaskBoardEvaluationSummary?
  let latestEvaluationBaselineRunID: String?
  let recentDispatch: TaskBoardDispatchSummary?
  let lastRun: TaskBoardOrchestratorRunSummary?
}

enum TaskBoardStepFlowRecoveryResolver {
  static func resolve(_ inputs: TaskBoardStepFlowRecoveryInputs) -> TaskBoardStepRecoveredFlow {
    let retainedItems = recoveryItems(
      liveItems: inputs.taskBoardItems,
      recentDispatch: inputs.recentDispatch
    )
    if let explicitID = inputs.lockedItemID
      ?? inputs.delivery?.applied.item.id
      ?? inputs.pickedSelection?.item.id
    {
      return recoveredFlow(
        itemID: explicitID,
        source: .explicit,
        items: retainedItems,
        inputs: inputs
      )
    }

    let heldIDs = Set(inputs.heldDispatches.items.map(\.boardItemId))
    let heldItems = retainedItems.filter {
      heldIDs.contains($0.id)
        && $0.deletedAt == nil
        && $0.status == .inProgress
        && $0.workflow?.currentStepId == "awaiting_delivery"
    }
    if let heldItem = newest(heldItems) {
      return recoveredFlow(
        itemID: heldItem.id,
        source: .heldDispatch,
        items: retainedItems,
        inputs: inputs
      )
    }
    if !heldIDs.isEmpty {
      return TaskBoardStepRecoveredFlow(
        item: nil,
        latestRecord: nil,
        dispatchPlan: nil,
        source: .heldDispatch,
        hasPicked: false
      )
    }

    let evaluationItems = inputs.taskBoardItems.filter { item in
      guard item.status == .blocked || item.status == .failed, item.hasLinkedSessionTask else {
        return false
      }
      guard item.deletedAt == nil else { return false }
      let record = evaluationRecord(itemID: item.id, inputs: inputs)
      return TaskBoardStepStageResolver.plan(
        for: TaskBoardStepStageInputs(item: item, latestRecord: record)
      ).primaryAction == .evaluate
    }
    if let evaluationItem = newest(evaluationItems) {
      return recoveredFlow(
        itemID: evaluationItem.id,
        source: .needsEvaluation,
        items: retainedItems,
        inputs: inputs
      )
    }

    guard let targetItem = inputs.targetItem else {
      return TaskBoardStepRecoveredFlow(
        item: nil,
        latestRecord: nil,
        dispatchPlan: nil,
        source: .none,
        hasPicked: false
      )
    }
    return recoveredFlow(
      itemID: targetItem.id,
      source: .target,
      items: retainedItems + [targetItem],
      inputs: inputs
    )
  }

  private static func recoveredFlow(
    itemID: String,
    source: TaskBoardStepRecoveredFlow.Source,
    items: [TaskBoardItem],
    inputs: TaskBoardStepFlowRecoveryInputs
  ) -> TaskBoardStepRecoveredFlow {
    let record = evaluationRecord(itemID: itemID, inputs: inputs)

    let item =
      items.first { $0.id == itemID }
      ?? matching(inputs.delivery?.applied.item, id: itemID)
      ?? matching(inputs.pickedSelection?.item, id: itemID)
      ?? matching(record?.item, id: itemID)

    let isHeld = inputs.heldDispatches.items.contains { $0.boardItemId == itemID }
    return TaskBoardStepRecoveredFlow(
      item: item,
      latestRecord: record,
      dispatchPlan: dispatchPlan(
        itemID: itemID,
        pickedSelection: inputs.pickedSelection,
        recentDispatch: inputs.recentDispatch,
        lastRun: inputs.lastRun
      ),
      source: source,
      hasPicked: inputs.pickedSelection?.item.id == itemID || isHeld
    )
  }

  // The orchestrator's own last-run summary now carries only a thin dispatch/
  // evaluation projection (board id + title, not the full TaskBoardItem), so
  // it can no longer seed this fallback cache directly. A
  // recently-dispatched item still comes through `recentDispatch` (the direct
  // dispatch endpoint's own full response) with no loss; an item the
  // background orchestrator touched with no matching live item and no recent
  // local dispatch simply falls out of the cache instead of showing a
  // reconstructed partial item.
  private static func recoveryItems(
    liveItems: [TaskBoardItem],
    recentDispatch: TaskBoardDispatchSummary?
  ) -> [TaskBoardItem] {
    var itemsByID = Dictionary(
      liveItems.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    for applied in recentDispatch?.applied ?? []
    where itemsByID[applied.item.id] == nil {
      itemsByID[applied.item.id] = applied.item
    }
    return Array(itemsByID.values)
  }

  private static func evaluationRecord(
    itemID: String,
    inputs: TaskBoardStepFlowRecoveryInputs
  ) -> TaskBoardEvaluationRecord? {
    if let latestEvaluation = inputs.latestEvaluation,
      inputs.lastRun?.runId == inputs.latestEvaluationBaselineRunID
    {
      return latestEvaluation.records.last { $0.boardItemId == itemID }
    }
    // `lastRun.evaluation.records` is the thin orchestrator-status projection
    // (no embedded `TaskBoardItem`), so it is widened back into the full
    // record shape with `item: nil` rather than changing this function's
    // (and every downstream `TaskBoardStepStage*` consumer's) return type.
    guard
      let thin = inputs.lastRun?.evaluation?.records.last(where: { $0.boardItemId == itemID })
    else {
      return nil
    }
    return TaskBoardEvaluationRecord(
      boardItemId: thin.boardItemId,
      sessionId: thin.sessionId,
      workItemId: thin.workItemId,
      outcome: thin.outcome,
      taskStatus: thin.taskStatus,
      boardStatus: thin.boardStatus,
      workflowStatus: thin.workflowStatus,
      updated: thin.updated,
      reason: thin.reason,
      item: nil
    )
  }

  private static func dispatchPlan(
    itemID: String,
    pickedSelection: TaskBoardDispatchSelection?,
    recentDispatch: TaskBoardDispatchSummary?,
    lastRun: TaskBoardOrchestratorRunSummary?
  ) -> TaskBoardDispatchPlan? {
    if pickedSelection?.item.id == itemID {
      return pickedSelection?.plan
    }
    return recentDispatch?.plans.first { $0.boardItemId == itemID }
      ?? lastRun?.dispatch?.plans.first { $0.boardItemId == itemID }
  }

  private static func newest(_ items: [TaskBoardItem]) -> TaskBoardItem? {
    items.max { left, right in
      if left.updatedAt != right.updatedAt { return left.updatedAt < right.updatedAt }
      return left.id > right.id
    }
  }

  private static func matching(_ item: TaskBoardItem?, id: String) -> TaskBoardItem? {
    item?.id == id ? item : nil
  }
}

enum TaskBoardStepCardPresentation: Equatable, Sendable {
  case empty
  case preview(TaskBoardStepColumn)
  case live(TaskBoardStepStage)

  static func resolve(
    plan: TaskBoardStepStagePlan,
    viewingColumn: TaskBoardStepColumn?
  ) -> Self {
    if let viewingColumn, viewingColumn != plan.column {
      return .preview(viewingColumn)
    }
    return plan.stage == .noTarget ? .empty : .live(plan.stage)
  }
}
