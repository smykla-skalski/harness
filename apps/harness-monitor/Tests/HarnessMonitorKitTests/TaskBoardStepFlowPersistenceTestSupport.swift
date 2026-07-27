import Foundation

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension TaskBoardStepFlowPersistenceTests {
  func railView(
    targetItem: TaskBoardItem?,
    taskBoardItems: [TaskBoardItem]
  ) async -> TaskBoardStepRailView {
    let store = await makeBootstrappedStore(client: RecordingHarnessClient())
    return TaskBoardStepRailView(
      store: store,
      status: TaskBoardOrchestratorStatus(
        enabled: true,
        running: false,
        stepMode: true,
        heldDispatches: TaskBoardHeldDispatchSummary(),
        settings: TaskBoardOrchestratorSettings(stepMode: true, policyVersion: "test")
      ),
      latestEvaluation: nil,
      workspace: nil,
      targetItem: targetItem,
      taskBoardItems: taskBoardItems,
      isActionInFlight: false,
      actions: TaskBoardOverviewActions(store: store, scope: .dashboard),
      flowDefaults: defaults
    )
  }

  func item(
    id: String,
    status: TaskBoardStatus,
    updatedAt: String = "2026-07-19T12:00:00Z",
    deletedAt: String? = nil
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
      workflow: nil,
      sessionId: "session-1",
      workItemId: "work-1",
      usage: TaskBoardUsage(),
      createdAt: "2026-07-19T11:00:00Z",
      updatedAt: updatedAt,
      deletedAt: deletedAt
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
}
