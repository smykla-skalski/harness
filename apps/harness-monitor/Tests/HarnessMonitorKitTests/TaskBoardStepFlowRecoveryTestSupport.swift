@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension TaskBoardStepFlowRecoveryTests {
  func recover(
    lockedItemID: String? = nil,
    targetItem: TaskBoardItem?,
    taskBoardItems: [TaskBoardItem],
    heldDispatches: TaskBoardHeldDispatchSummary = TaskBoardHeldDispatchSummary(),
    evaluation: EvaluationContext = EvaluationContext()
  ) -> TaskBoardStepRecoveredFlow {
    TaskBoardStepFlowRecoveryResolver.resolve(
      TaskBoardStepFlowRecoveryInputs(
        lockedItemID: lockedItemID,
        pickedSelection: nil,
        delivery: nil,
        targetItem: targetItem,
        taskBoardItems: taskBoardItems,
        heldDispatches: heldDispatches,
        latestEvaluation: evaluation.latestEvaluation,
        latestEvaluationBaselineRunID: evaluation.baselineRunID,
        recentDispatch: nil,
        lastRun: evaluation.lastRun
      )
    )
  }

  func railView(
    store: HarnessMonitorStore,
    status: TaskBoardOrchestratorStatus,
    targetItem: TaskBoardItem?,
    taskBoardItems: [TaskBoardItem]
  ) -> TaskBoardStepRailView {
    TaskBoardStepRailView(
      store: store,
      status: status,
      latestEvaluation: nil,
      workspace: nil,
      targetItem: targetItem,
      taskBoardItems: taskBoardItems,
      isActionInFlight: false,
      actions: TaskBoardOverviewActions(store: store, scope: .dashboard)
    )
  }

  func orchestratorStatus(
    heldDispatches: TaskBoardHeldDispatchSummary = TaskBoardHeldDispatchSummary(),
    lastRun: TaskBoardOrchestratorRunSummary? = nil
  ) -> TaskBoardOrchestratorStatus {
    TaskBoardOrchestratorStatus(
      enabled: true,
      running: false,
      stepMode: true,
      heldDispatches: heldDispatches,
      lastRun: lastRun,
      settings: TaskBoardOrchestratorSettings(stepMode: true, policyVersion: "test")
    )
  }

  func waitForDelivery(itemID: String, client: RecordingHarnessClient) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline {
      if client.recordedCalls().contains(
        .deliverTaskBoardDispatch(itemID: itemID, dryRun: false)
      ) {
        return true
      }
      await Task.yield()
    }
    return false
  }

  func waitForStepAction(_ state: TaskBoardStepRailState) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline {
      if !state.isRunning { return true }
      await Task.yield()
    }
    return false
  }

  func item(
    id: String,
    status: TaskBoardStatus,
    workflow: TaskBoardWorkflowState? = nil,
    updatedAt: String = "2026-07-19T12:00:00Z"
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: "Board item \(id)",
      body: "Body",
      status: status,
      priority: .medium,
      tags: [],
      projectId: "project-1",
      agentMode: .interactive,
      externalRefs: [],
      planning: TaskBoardPlanningState(),
      workflow: workflow,
      sessionId: "session-1",
      workItemId: "work-1",
      usage: TaskBoardUsage(),
      createdAt: "2026-07-19T11:00:00Z",
      updatedAt: updatedAt,
      deletedAt: nil
    )
  }

  func heldDispatch(for item: TaskBoardItem) -> TaskBoardHeldDispatchItem {
    TaskBoardHeldDispatchItem(
      intentId: "intent-\(item.id)",
      boardItemId: item.id,
      sessionId: item.sessionId ?? "session-1",
      workItemId: item.workItemId ?? "work-1"
    )
  }

  func appliedTask(for item: TaskBoardItem) -> TaskBoardDispatchAppliedTask {
    TaskBoardDispatchAppliedTask(
      boardItemId: item.id,
      sessionId: item.sessionId ?? "session-1",
      workItemId: item.workItemId ?? "work-1",
      item: item
    )
  }

  func dispatchPlan(for item: TaskBoardItem) -> TaskBoardDispatchPlan {
    TaskBoardDispatchPlan(
      boardItemId: item.id,
      renderedPrompt: "durable prompt",
      readiness: TaskBoardDispatchReadiness(state: "ready", reason: nil),
      session: TaskBoardSessionIntent(
        kind: "existing",
        sessionId: item.sessionId,
        title: item.title,
        context: item.body,
        projectId: item.projectId
      ),
      task: TaskBoardTaskCreationIntent(
        title: item.title,
        context: item.body,
        severity: .medium,
        suggestedFix: nil,
        source: .manual,
        tags: [],
        externalRefs: []
      ),
      worker: TaskBoardWorkerIntent(mode: item.agentMode),
      reviewer: TaskBoardReviewerIntent(
        phase: "review",
        suggestedPersona: "reviewer",
        requiredConsensus: 1
      ),
      evaluator: TaskBoardEvaluatorIntent(phase: "evaluate", mode: .evaluate),
      policy: nil
    )
  }

  func lastRun(
    runID: String = "run-1",
    evaluation: TaskBoardEvaluationSummary? = nil
  ) -> TaskBoardOrchestratorRunSummary {
    TaskBoardOrchestratorRunSummary(
      runId: runID,
      startedAt: "2026-07-19T11:59:00Z",
      completedAt: "2026-07-19T12:00:00Z",
      status: .completed,
      dryRun: false,
      sync: TaskBoardSyncSummary(total: 0, providers: []),
      audit: TaskBoardAuditSummary(total: 0, ready: 0, blocked: 0, deleted: 0, byStatus: []),
      evaluation: evaluation
    )
  }

  struct EvaluationContext {
    var latestEvaluation: TaskBoardEvaluationSummary?
    var baselineRunID: String?
    var lastRun: TaskBoardOrchestratorRunSummary?
  }
}
