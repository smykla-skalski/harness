import HarnessMonitorKit
import SwiftUI

#Preview("Task Board Overview") {
  TaskBoardOverviewView(
    snapshot: TaskBoardPreviewFixtures.snapshot,
    taskBoardItems: TaskBoardPreviewFixtures.store.globalTaskBoardItems,
    store: TaskBoardPreviewFixtures.store,
    orchestratorStatus: TaskBoardPreviewFixtures.orchestratorStatus,
    evaluationSummary: TaskBoardPreviewFixtures.evaluationSummary,
    actions: TaskBoardOverviewActions(store: TaskBoardPreviewFixtures.store, scope: .dashboard),
    decisionItems: [],
    decisionsByID: [:]
  )
  .padding(24)
  .frame(width: 1_120)
}

private enum TaskBoardPreviewFixtures {
  @MainActor static let store: HarnessMonitorStore = {
    HarnessMonitorPreviewStoreFactory.makeStore(for: .taskBoardBoardOnly)
  }()

  static let evaluationSummary = TaskBoardEvaluationSummary(
    total: 12,
    evaluated: 8,
    updated: 3,
    blocked: 1
  )

  static let orchestratorStatus = TaskBoardOrchestratorStatus(
    enabled: true,
    running: false,
    workflowExecutionCounts: [
      TaskBoardWorkflowExecutionCount(status: .running, count: 1),
      TaskBoardWorkflowExecutionCount(status: .paused, count: 1),
    ],
    settings: TaskBoardOrchestratorSettings(
      enabledWorkflows: [.defaultTask, .prReview],
      dryRunDefault: false,
      policyVersion: "preview"
    )
  )

  static let snapshot = TaskBoardInboxSnapshot(
    sessions: [PreviewFixtures.taskDropSummary, secondarySession],
    detailsBySessionID: [
      PreviewFixtures.taskDropSummary.sessionId: SessionDetail(
        session: PreviewFixtures.taskDropSummary,
        agents: PreviewFixtures.agents,
        tasks: PreviewFixtures.taskDropTasks,
        signals: [],
        observer: nil,
        agentActivity: []
      ),
      secondarySession.sessionId: SessionDetail(
        session: secondarySession,
        agents: PreviewFixtures.agents,
        tasks: secondaryTasks,
        signals: [],
        observer: nil,
        agentActivity: []
      ),
    ],
    generatedAt: Date(timeIntervalSinceReferenceDate: 801_000_000),
    isFromCache: true
  )

  private static let secondarySession = SessionSummary(
    projectId: "project-task-board",
    projectName: "harness",
    projectDir: "/Users/example/Projects/harness",
    contextRoot: "/Users/example/Library/Application Support/harness/sessions/harness",
    sessionId: "sess-task-board",
    worktreePath: "/Users/example/Library/Application Support/harness/task-board/workspace",
    sharedPath: "/Users/example/Library/Application Support/harness/task-board/memory",
    originPath: "/Users/example/Projects/harness",
    branchRef: "harness/task-board",
    title: "Task Board Follow-up",
    context: "Review shared task state across sessions.",
    status: .active,
    createdAt: "2026-05-14T09:00:00Z",
    updatedAt: "2026-05-14T10:30:00Z",
    lastActivityAt: "2026-05-14T10:30:00Z",
    leaderId: "leader-task-board",
    observeId: nil,
    pendingLeaderTransfer: nil,
    metrics: SessionMetrics(
      agentCount: 2,
      activeAgentCount: 2,
      openTaskCount: 1,
      inProgressTaskCount: 1,
      awaitingReviewTaskCount: 1,
      blockedTaskCount: 0,
      completedTaskCount: 0
    )
  )

  private static let secondaryTasks = [
    WorkItem(
      taskId: "task-board-review",
      title: "Review inbox grouping",
      context: "Confirm lane grouping and row density.",
      severity: .critical,
      status: .awaitingReview,
      assignedTo: "worker-codex",
      createdAt: "2026-05-14T09:05:00Z",
      updatedAt: "2026-05-14T10:25:00Z",
      createdBy: "leader-task-board",
      notes: [],
      suggestedFix: nil,
      source: .manual,
      blockedReason: nil,
      completedAt: nil,
      checkpointSummary: nil
    ),
    WorkItem(
      taskId: "task-board-refresh",
      title: "Wire cached refresh entry point",
      context: "Load cached session details into the inbox snapshot.",
      severity: .medium,
      status: .inProgress,
      assignedTo: "worker-codex",
      createdAt: "2026-05-14T09:15:00Z",
      updatedAt: "2026-05-14T10:20:00Z",
      createdBy: "leader-task-board",
      notes: [],
      suggestedFix: nil,
      source: .manual,
      blockedReason: nil,
      completedAt: nil,
      checkpointSummary: nil
    ),
  ]
}
