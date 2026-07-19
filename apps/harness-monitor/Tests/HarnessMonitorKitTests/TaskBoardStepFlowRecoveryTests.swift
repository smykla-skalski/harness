import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Step Mode flow recovery")
struct TaskBoardStepFlowRecoveryTests {
  @Test("Successful Sync preserves every active-flow identity field")
  func successfulSyncPreservesActiveFlow() {
    let item = item(id: "active", status: .inProgress)
    let selection = TaskBoardDispatchSelection(item: item, plan: dispatchPlan(for: item))
    let delivery = TaskBoardDispatchDelivery(
      intentId: "intent-active",
      applied: appliedTask(for: item),
      renderedPrompt: "durable prompt"
    )
    let state = TaskBoardStepRailState()
    state.pickedSelection = selection
    state.delivery = delivery
    state.lockedItemID = item.id
    let initialRefreshGeneration = state.approvalRefreshGeneration

    #expect(state.beginExternalSync(itemID: item.id))
    state.finishExternalSync(succeeded: true)

    #expect(state.pickedSelection == selection)
    #expect(state.delivery == delivery)
    #expect(state.lockedItemID == item.id)
    #expect(state.approvalRefreshGeneration == initialRefreshGeneration + 1)
    #expect(!state.isRunning)
  }

  @Test("Successful Sync pins an unpicked active target across refreshed Todo order")
  func successfulSyncPinsActiveTarget() async {
    let active = item(id: "active", status: .todo, updatedAt: "2026-07-19T12:00:00Z")
    let newTop = item(id: "new-top", status: .todo, updatedAt: "2026-07-19T12:01:00Z")
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([active])
    client.configureTaskBoardSync(
      summary: TaskBoardSyncSummary(total: 2, providers: []),
      importedItems: [newTop, active]
    )
    let store = await makeBootstrappedStore(client: client)
    let view = railView(
      store: store,
      status: orchestratorStatus(),
      targetItem: active,
      taskBoardItems: [active]
    )

    view.runPrimary(.sync)
    guard let confirmation = view.stepRailState.confirmation else {
      Issue.record("Expected Sync confirmation")
      return
    }
    #expect(confirmation.itemID == active.id)
    #expect(view.stepRailState.lockedItemID == active.id)
    view.runConfirmation(confirmation)
    let finished = await waitForStepAction(view.stepRailState)
    let flow = recover(
      lockedItemID: view.stepRailState.lockedItemID,
      targetItem: newTop,
      taskBoardItems: [newTop, active]
    )

    #expect(finished)
    #expect(
      client.recordedCalls().contains(
        .syncTaskBoard(direction: .pull, dryRun: false, status: nil, provider: nil)
      )
    )
    #expect(flow.source == .explicit)
    #expect(flow.item?.id == active.id)
  }

  @Test("State recreation reacquires a held awaiting-delivery item before top Todo")
  func remountRecoversHeldItem() {
    let topTodo = item(id: "top-todo", status: .todo, updatedAt: "2026-07-19T12:04:00Z")
    let held = item(
      id: "held-item",
      status: .inProgress,
      workflow: TaskBoardWorkflowState(status: .running, currentStepId: "awaiting_delivery"),
      updatedAt: "2026-07-19T12:03:00Z"
    )
    let heldSummary = TaskBoardHeldDispatchSummary(
      count: 1,
      items: [heldDispatch(for: held)]
    )

    let flow = recover(
      targetItem: topTodo,
      taskBoardItems: [topTodo, held],
      heldDispatches: heldSummary
    )

    #expect(flow.source == .heldDispatch)
    #expect(flow.item?.id == held.id)
    #expect(flow.hasPicked)
  }

  @Test("Unresolved held identity suppresses an unrelated top Todo")
  func unresolvedHeldItemSuppressesTarget() {
    let topTodo = item(id: "top-todo", status: .todo)
    let heldSummary = TaskBoardHeldDispatchSummary(
      count: 1,
      items: [
        TaskBoardHeldDispatchItem(
          intentId: "intent-missing",
          boardItemId: "missing-held-item",
          sessionId: "session-missing",
          workItemId: "work-missing"
        )
      ]
    )

    let flow = recover(
      targetItem: topTodo,
      taskBoardItems: [topTodo],
      heldDispatches: heldSummary
    )

    #expect(flow.source == .heldDispatch)
    #expect(flow.item == nil)
  }

  @Test("State recreation reacquires latest failed item that still needs Evaluate")
  func remountRecoversLatestEvaluationItem() {
    let topTodo = item(id: "top-todo", status: .todo, updatedAt: "2026-07-19T12:05:00Z")
    let olderBlocked = item(
      id: "older-blocked",
      status: .blocked,
      workflow: TaskBoardWorkflowState(status: .failed, currentStepId: "blocked"),
      updatedAt: "2026-07-19T12:01:00Z"
    )
    let latestFailed = item(
      id: "latest-failed",
      status: .failed,
      workflow: TaskBoardWorkflowState(status: .failed, currentStepId: "missing_task"),
      updatedAt: "2026-07-19T12:03:00Z"
    )

    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let recreated = railView(
      store: store,
      status: orchestratorStatus(),
      targetItem: topTodo,
      taskBoardItems: [topTodo, olderBlocked, latestFailed]
    )

    #expect(recreated.stepFlow.source == .needsEvaluation)
    #expect(recreated.activeItem?.id == latestFailed.id)
    #expect(recreated.stagePlan.primaryAction == .evaluate)
  }

  @Test("Durable completed record excludes stale failed item from recovery")
  func durableRecordExcludesFinishedFailedItem() {
    let topTodo = item(id: "top-todo", status: .todo, updatedAt: "2026-07-19T12:05:00Z")
    let blocked = item(
      id: "blocked",
      status: .blocked,
      workflow: TaskBoardWorkflowState(status: .failed, currentStepId: "blocked"),
      updatedAt: "2026-07-19T12:01:00Z"
    )
    let staleFailed = item(
      id: "stale-failed",
      status: .failed,
      workflow: TaskBoardWorkflowState(status: .failed, currentStepId: "blocked"),
      updatedAt: "2026-07-19T12:04:00Z"
    )
    let completedRecord = TaskBoardEvaluationRecord(
      boardItemId: staleFailed.id,
      outcome: .completed,
      taskStatus: .done,
      boardStatus: .done
    )

    let flow = recover(
      targetItem: topTodo,
      taskBoardItems: [topTodo, blocked, staleFailed],
      evaluation: EvaluationContext(
        lastRun: lastRun(evaluation: TaskBoardEvaluationSummary(records: [completedRecord]))
      )
    )

    #expect(flow.source == .needsEvaluation)
    #expect(flow.item?.id == blocked.id)
  }

  @Test("Superseded standalone evaluation does not hide a failed item")
  func supersededEvaluationDoesNotHideFailedItem() {
    let failed = item(
      id: "failed",
      status: .failed,
      workflow: TaskBoardWorkflowState(status: .failed, currentStepId: "blocked")
    )
    let staleCompleted = TaskBoardEvaluationSummary(
      records: [
        TaskBoardEvaluationRecord(
          boardItemId: failed.id,
          outcome: .completed,
          taskStatus: .done,
          boardStatus: .done
        )
      ]
    )
    let flow = recover(
      targetItem: item(id: "top-todo", status: .todo),
      taskBoardItems: [failed],
      evaluation: EvaluationContext(
        latestEvaluation: staleCompleted,
        baselineRunID: "superseded-run",
        lastRun: lastRun(runID: "current-run")
      )
    )

    #expect(flow.source == .needsEvaluation)
    #expect(flow.item?.id == failed.id)
  }

  @Test("Current item-scoped evaluation never falls through to older run records")
  func currentEvaluationIsExclusive() {
    let failed = item(
      id: "failed",
      status: .failed,
      workflow: TaskBoardWorkflowState(status: .failed, currentStepId: "blocked")
    )
    let other = item(id: "other", status: .inProgress)
    let olderCompleted = TaskBoardEvaluationRecord(
      boardItemId: failed.id,
      outcome: .completed,
      taskStatus: .done,
      boardStatus: .done
    )
    let currentOther = TaskBoardEvaluationRecord(
      boardItemId: other.id,
      outcome: .workerRunning,
      taskStatus: .inProgress
    )
    let flow = recover(
      targetItem: nil,
      taskBoardItems: [failed],
      evaluation: EvaluationContext(
        latestEvaluation: TaskBoardEvaluationSummary(records: [currentOther]),
        baselineRunID: "current-run",
        lastRun: lastRun(
          runID: "current-run",
          evaluation: TaskBoardEvaluationSummary(records: [olderCompleted])
        )
      )
    )

    #expect(flow.source == .needsEvaluation)
    #expect(flow.item?.id == failed.id)
  }

  @Test("Missing live item never resurrects a stale durable blocked snapshot")
  func staleDurableSnapshotIsNotCandidate() {
    let staleBlocked = item(
      id: "worked-item",
      status: .blocked,
      workflow: TaskBoardWorkflowState(status: .failed, currentStepId: "blocked")
    )
    let durableRecord = TaskBoardEvaluationRecord(
      boardItemId: staleBlocked.id,
      outcome: .blocked,
      taskStatus: .blocked,
      item: staleBlocked
    )
    let durable = EvaluationContext(
      lastRun: lastRun(evaluation: TaskBoardEvaluationSummary(records: [durableRecord]))
    )
    let topTodo = item(id: "top-todo", status: .todo)
    let recovered = recover(
      targetItem: topTodo,
      taskBoardItems: [topTodo],
      evaluation: durable
    )

    #expect(recovered.source == .target)
    #expect(recovered.item?.id == topTodo.id)
  }

  @Test("Fresh rail view state reacquires held work and enables Deliver")
  func recreatedRailViewRecoversHeldItem() {
    let held = item(
      id: "held-item",
      status: .inProgress,
      workflow: TaskBoardWorkflowState(status: .running, currentStepId: "awaiting_delivery")
    )
    let heldSummary = TaskBoardHeldDispatchSummary(
      count: 1,
      items: [heldDispatch(for: held)]
    )
    let topTodo = item(id: "other-todo", status: .todo)
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let status = orchestratorStatus(heldDispatches: heldSummary)
    let original = railView(
      store: store,
      status: status,
      targetItem: topTodo,
      taskBoardItems: [topTodo, held]
    )
    let recreated = railView(
      store: store,
      status: status,
      targetItem: topTodo,
      taskBoardItems: [topTodo, held]
    )

    #expect(original.activeItem?.id == held.id)
    #expect(recreated.activeItem?.id == held.id)
    #expect(recreated.stagePlan.primaryAction == .deliver)
    #expect(recreated.deliveryItemID == held.id)
  }

  @Test("Deliver after selection loss sends the held item without preparing it again")
  func deliverUsesHeldItemAfterSelectionLoss() async {
    let held = item(
      id: "held-item",
      status: .inProgress,
      workflow: TaskBoardWorkflowState(status: .running, currentStepId: "awaiting_delivery")
    )
    let heldSummary = TaskBoardHeldDispatchSummary(
      count: 1,
      items: [heldDispatch(for: held)]
    )
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([held])
    let store = await makeBootstrappedStore(client: client)
    let view = railView(
      store: store,
      status: orchestratorStatus(heldDispatches: heldSummary),
      targetItem: nil,
      taskBoardItems: [held]
    )
    view.runPrimary(.deliver)
    guard let confirmation = view.stepRailState.confirmation else {
      Issue.record("Expected Deliver confirmation")
      return
    }
    #expect(confirmation.itemID == held.id)
    #expect(view.stepRailState.lockedItemID == held.id)
    view.runConfirmation(confirmation)
    let delivered = await waitForDelivery(itemID: held.id, client: client)
    let calls = client.recordedCalls()

    #expect(view.deliveryItemID == held.id)
    #expect(delivered)
    #expect(calls.contains(.deliverTaskBoardDispatch(itemID: held.id, dryRun: false)))
    #expect(
      !calls.contains {
        if case .dispatchTaskBoard = $0 { return true }
        return false
      }
    )
  }

  @Test("Ready-to-deliver stage hides Deliver when durable eligibility disappears")
  func readyToDeliverRequiresSafeTarget() {
    let held = item(
      id: "held-item",
      status: .inProgress,
      workflow: TaskBoardWorkflowState(status: .running, currentStepId: "awaiting_delivery")
    )
    let plan = TaskBoardStepStageResolver.plan(
      for: TaskBoardStepStageInputs(item: held, hasPicked: true, canDeliver: false)
    )

    #expect(plan.stage == .readyToDeliver)
    #expect(plan.primaryAction == nil)
    #expect(plan.whatNext.contains("reacquire the held delivery"))
  }

  @Test("No-target read-ahead renders the selected preview before empty state")
  func noTargetReadAheadUsesPreview() {
    let plan = TaskBoardStepStageResolver.plan(for: TaskBoardStepStageInputs(item: nil))

    #expect(
      TaskBoardStepCardPresentation.resolve(plan: plan, viewingColumn: .inProgress)
        == .preview(.inProgress)
    )
    #expect(TaskBoardStepCardPresentation.resolve(plan: plan, viewingColumn: nil) == .empty)
  }

}
