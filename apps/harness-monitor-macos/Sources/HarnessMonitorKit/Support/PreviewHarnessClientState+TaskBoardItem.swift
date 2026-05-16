import Foundation

extension TaskBoardItem {
  func applyingPreviewUpdate(_ request: TaskBoardUpdateItemRequest) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: schemaVersion,
      id: id,
      title: request.title ?? title,
      body: request.body ?? body,
      status: request.status ?? status,
      priority: request.priority ?? priority,
      tags: request.tags ?? tags,
      projectId: request.clearProjectId ? nil : request.projectId ?? projectId,
      targetProjectTypes: request.targetProjectTypes ?? targetProjectTypes,
      agentMode: request.agentMode ?? agentMode,
      externalRefs: request.externalRefs ?? externalRefs,
      planning: request.clearPlanning
        ? TaskBoardPlanningState()
        : request.planning ?? planning,
      workflow: request.clearWorkflow ? nil : request.workflow ?? workflow,
      sessionId: request.clearSessionId ? nil : request.sessionId ?? sessionId,
      workItemId: request.clearWorkItemId ? nil : request.workItemId ?? workItemId,
      usage: usage,
      createdAt: createdAt,
      updatedAt: PreviewHarnessClientState.mutationTimestamp,
      deletedAt: deletedAt
    )
  }

  func applyingPreviewPlanning(
    status: TaskBoardStatus,
    planning: TaskBoardPlanningState
  ) -> TaskBoardItem {
    applyingPreviewUpdate(
      TaskBoardUpdateItemRequest(status: status, planning: planning)
    )
  }

  func applyingPreviewDispatch() -> TaskBoardItem {
    applyingPreviewUpdate(
      TaskBoardUpdateItemRequest(
        status: .inProgress,
        workflow: TaskBoardWorkflowState(
          executionId: "preview-exec-\(id)",
          status: .running,
          currentStepId: "dispatch",
          attempts: (workflow?.attempts ?? 0) + 1,
          branch: workflow?.branch ?? "preview/\(id)",
          worktree: workflow?.worktree,
          policyTraceIds: ["preview-policy-\(id)"]
        ),
        sessionId: sessionId ?? "preview-session-\(id)",
        workItemId: workItemId ?? "preview-task-\(id)"
      )
    )
  }

  func applyingPreviewEvaluation(
    status: TaskBoardStatus,
    workflowStatus: TaskBoardWorkflowStatus
  ) -> TaskBoardItem {
    applyingPreviewUpdate(
      TaskBoardUpdateItemRequest(
        status: status,
        workflow: TaskBoardWorkflowState(
          executionId: workflow?.executionId,
          status: workflowStatus,
          currentStepId: workflowStatus == .completed ? nil : workflow?.currentStepId,
          attempts: workflow?.attempts ?? 0,
          branch: workflow?.branch,
          worktree: workflow?.worktree,
          prNumber: workflow?.prNumber,
          prUrl: workflow?.prUrl,
          lastError: workflow?.lastError,
          policyTraceIds: workflow?.policyTraceIds ?? []
        )
      )
    )
  }

  func previewEvaluationRecord(
    outcome: TaskBoardEvaluationOutcome,
    updated: Bool
  ) -> TaskBoardEvaluationRecord {
    TaskBoardEvaluationRecord(
      boardItemId: id,
      sessionId: sessionId,
      workItemId: workItemId,
      outcome: outcome,
      taskStatus: status.previewTaskStatus,
      boardStatus: status,
      workflowStatus: workflow?.status,
      updated: updated,
      item: self
    )
  }
}
