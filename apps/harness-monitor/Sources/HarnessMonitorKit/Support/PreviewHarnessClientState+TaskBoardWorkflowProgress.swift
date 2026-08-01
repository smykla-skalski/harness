import Foundation

extension PreviewHarnessClientState {
  func taskBoardItemWorkflowProgress(id: String) throws -> TaskBoardWorkflowProgressResponse {
    _ = try currentTaskBoardItem(id: id)
    return taskBoardWorkflowProgressByItemID[id] ?? TaskBoardWorkflowProgressResponse()
  }

  static func seededTaskBoardWorkflowProgress(
    items: [TaskBoardItem]
  ) -> [String: TaskBoardWorkflowProgressResponse] {
    Dictionary(
      uniqueKeysWithValues: items.compactMap { item in
        guard
          let workflow = item.workflow,
          let executionID = workflow.executionId,
          !executionID.isEmpty,
          item.workflowKind == .prFixReview || item.workflowKind == .prFix
        else {
          return nil
        }
        return (
          item.id,
          previewWorkflowProgress(item: item, workflow: workflow, executionID: executionID)
        )
      }
    )
  }

  private static func previewWorkflowProgress(
    item: TaskBoardItem,
    workflow: TaskBoardWorkflowState,
    executionID: String
  ) -> TaskBoardWorkflowProgressResponse {
    let head = workflow.prHeadRevision ?? String(repeating: "b", count: 40)
    let triage = TaskBoardDependencyTriageResult(
      schemaVersion: 1,
      repository: item.executionRepository ?? "example/harness",
      pullRequestNumber: workflow.prNumber ?? 920,
      exactHeadRevision: head,
      dependency: TaskBoardDependencyIdentity(
        name: "serde",
        ecosystem: "cargo",
        currentVersion: "1.0.219",
        targetVersion: "1.0.221",
        updateClass: .patch
      ),
      checks: [
        TaskBoardDependencyCheck(
          name: "Rust",
          state: .failed,
          detailsUrl: "https://github.com/example/harness/actions/runs/920"
        ),
        TaskBoardDependencyCheck(
          name: "Monitor",
          state: .pending,
          detailsUrl: "https://github.com/example/harness/actions/runs/921"
        ),
      ],
      conflicts: TaskBoardDependencyConflictEvidence(
        state: .clean,
        summary: "The pull request applies cleanly to its exact head."
      ),
      approvals: TaskBoardDependencyApprovalEvidence(current: 1, required: 1),
      safetyAssumption: "The repair stays within dependency-owned generated files.",
      disposition: .fixRequired,
      requiredTools: ["github.read", "codex.dispatch"],
      nextSteps: [
        TaskBoardDependencyTriageStep(
          order: 1,
          action: "inspect_failed_checks",
          reason: "Use exact-head diagnostics before changing the patch."
        ),
        TaskBoardDependencyTriageStep(
          order: 2,
          action: "dispatch_fixer",
          reason: "Apply the smallest proven repair and rerun failed checks."
        ),
      ]
    )
    return TaskBoardWorkflowProgressResponse(
      progress: TaskBoardWorkflowProgress(
        executionId: executionID,
        workflowKind: item.workflowKind ?? .prFixReview,
        phase: .implementation,
        state: .running,
        exactHeadRevision: head,
        currentRuntime: "codex",
        currentModel: "gpt-5.3-codex-spark",
        triage: TaskBoardDependencyRouteRecord(
          routeId: "dependency-preview-route",
          repository: triage.repository,
          pullRequestNumber: triage.pullRequestNumber,
          exactHeadRevision: head,
          status: .fixRequested,
          reason: "The failed Rust check requires a scoped repair.",
          sourceResult: triage
        ),
        attempts: previewWorkflowAttempts(),
        createdAt: "2026-07-30T08:10:00Z",
        updatedAt: "2026-07-30T08:11:22Z"
      )
    )
  }

  private static func previewWorkflowAttempts() -> [TaskBoardWorkflowAttemptProgress] {
    [
      TaskBoardWorkflowAttemptProgress(
        actionKey: "dependency_triage",
        attempt: 1,
        state: .completed,
        runtime: "openrouter",
        model: "deepseek/deepseek-v4-flash",
        report: "Classified the update as a safe patch with one failing required check.",
        startedAt: "2026-07-30T08:10:00Z",
        updatedAt: "2026-07-30T08:10:14Z",
        completedAt: "2026-07-30T08:10:14Z"
      ),
      TaskBoardWorkflowAttemptProgress(
        actionKey: "dependency_fix",
        attempt: 1,
        state: .running,
        runtime: "codex",
        model: "gpt-5.3-codex-spark",
        report: "Inspecting the failed Rust check against the selected revision.",
        startedAt: "2026-07-30T08:11:00Z",
        updatedAt: "2026-07-30T08:11:22Z"
      ),
    ]
  }
}
