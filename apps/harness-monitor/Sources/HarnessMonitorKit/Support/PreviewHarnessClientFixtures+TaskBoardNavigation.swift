import Foundation

extension PreviewHarnessClient.Fixtures {
  static let linkedReviewTaskBoardItem = TaskBoardItem(
    schemaVersion: 1,
    id: "preview-linked-review",
    title: "Review pull request #1284",
    body: "Keep the originating review ticket reachable after dispatch.",
    status: .inReview,
    priority: .high,
    tags: ["preview", "review"],
    projectId: "project-6ccf8d0a",
    executionRepository: "smykla-skalski/harness",
    agentMode: .evaluate,
    workflowKind: .prReview,
    externalRefs: [],
    planning: TaskBoardPlanningState(summary: "Review the recorded pull request head"),
    workflow: TaskBoardWorkflowState(
      status: .completed,
      prNumber: 1284,
      prUrl: "https://github.com/smykla-skalski/harness/pull/1284",
      prHeadRevision: String(repeating: "a", count: 40)
    ),
    sessionId: PreviewFixtures.summary.sessionId,
    workItemId: "task-review-1284",
    usage: TaskBoardUsage(),
    createdAt: "2026-03-28T14:05:00Z",
    updatedAt: "2026-03-28T14:07:00Z",
    deletedAt: nil
  )
}
