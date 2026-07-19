import HarnessMonitorKit
import SwiftUI

#Preview("Step Mode - ready to pick") {
  TaskBoardStepRailPreviewFixtures.panel(
    item: TaskBoardStepRailPreviewFixtures.item(status: .todo),
    record: nil
  )
}

#Preview("Step Mode - worker running") {
  TaskBoardStepRailPreviewFixtures.panel(
    item: TaskBoardStepRailPreviewFixtures.item(status: .inProgress, currentStepId: "worker"),
    record: nil
  )
}

#Preview("Step Mode - awaiting review") {
  TaskBoardStepRailPreviewFixtures.panel(
    item: TaskBoardStepRailPreviewFixtures.item(status: .toReview),
    record: TaskBoardStepRailPreviewFixtures.record(taskStatus: .awaitingReview, outcome: .reviewPending)
  )
}

#Preview("Step Mode - changes requested") {
  TaskBoardStepRailPreviewFixtures.panel(
    item: TaskBoardStepRailPreviewFixtures.item(status: .inReview, prUrl: "https://example.com/pr/7"),
    record: TaskBoardStepRailPreviewFixtures.record(
      taskStatus: .inReview,
      outcome: .reviewChangesRequested,
      reason: "Tighten the retry backoff"
    )
  )
}

#Preview("Step Mode - done") {
  TaskBoardStepRailPreviewFixtures.panel(
    item: TaskBoardStepRailPreviewFixtures.item(status: .done),
    record: nil
  )
}

@MainActor
private enum TaskBoardStepRailPreviewFixtures {
  static let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .taskBoardBoardOnly)

  static let status = TaskBoardOrchestratorStatus(
    enabled: true,
    running: false,
    stepMode: true,
    settings: TaskBoardOrchestratorSettings(
      enabledWorkflows: [.defaultTask, .prReview],
      dryRunDefault: false,
      policyVersion: "preview"
    )
  )

  static func item(
    status: TaskBoardStatus,
    currentStepId: String? = nil,
    prUrl: String? = nil
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: "board-preview",
      title: "Wire cached refresh entry point",
      body: "Load cached session details into the inbox snapshot.",
      status: status,
      priority: .medium,
      tags: [],
      projectId: "project-task-board",
      targetProjectTypes: [],
      agentMode: .interactive,
      externalRefs: [],
      planning: TaskBoardPlanningState(),
      workflow: TaskBoardWorkflowState(status: .running, currentStepId: currentStepId, prUrl: prUrl),
      sessionId: "sess-task-board",
      workItemId: "task-board-refresh",
      usage: TaskBoardUsage(),
      createdAt: "2026-05-14T10:00:00Z",
      updatedAt: "2026-05-14T10:01:00Z",
      deletedAt: nil
    )
  }

  static func record(
    taskStatus: TaskStatus,
    outcome: TaskBoardEvaluationOutcome,
    reason: String? = nil
  ) -> TaskBoardEvaluationRecord {
    TaskBoardEvaluationRecord(
      boardItemId: "board-preview",
      outcome: outcome,
      taskStatus: taskStatus,
      reason: reason
    )
  }

  static func panel(item: TaskBoardItem, record: TaskBoardEvaluationRecord?) -> some View {
    TaskBoardStepRailView(
      store: store,
      status: status,
      latestEvaluation: record.map { TaskBoardEvaluationSummary(records: [$0]) },
      workspace: nil,
      targetItem: item,
      taskBoardItems: [item],
      isActionInFlight: false,
      actions: TaskBoardOverviewActions(store: store, scope: .dashboard)
    )
    .padding(24)
    .frame(width: 460)
  }
}
