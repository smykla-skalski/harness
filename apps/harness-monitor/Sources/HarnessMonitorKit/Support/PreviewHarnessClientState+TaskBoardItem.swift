import CryptoKit
import Foundation

extension TaskBoardItem {
  /// The daemon assigns every attributable item a project id during the v51
  /// backfill. Preview fixtures predate the column, so derive the same
  /// attribution here. Without it the catalog is empty and every card falls
  /// back to its agent mode, which is the behaviour this feature removes.
  func applyingPreviewAttribution() -> TaskBoardItem {
    guard sourceProjectId == nil,
      let identity = TaskBoardProjectSummary.inferredIdentity(from: self)
    else {
      return self
    }
    return TaskBoardItem(
      schemaVersion: schemaVersion,
      id: id,
      title: title,
      body: body,
      status: status,
      priority: priority,
      tags: tags,
      projectId: projectId,
      sourceProjectId: Self.previewProjectId(for: identity),
      executionRepository: executionRepository,
      targetProjectTypes: targetProjectTypes,
      agentMode: agentMode,
      kind: kind,
      externalRefs: externalRefs,
      importedFromProvider: importedFromProvider,
      planning: planning,
      workflow: workflow,
      sessionId: sessionId,
      workItemId: workItemId,
      usage: usage,
      parentItemId: parentItemId,
      childOrder: childOrder,
      lanePosition: lanePosition,
      laneOrigin: laneOrigin,
      laneSetAt: laneSetAt,
      createdAt: createdAt,
      updatedAt: updatedAt,
      deletedAt: deletedAt
    )
  }

  /// Stable across runs and shaped like a real identifier, so preview data
  /// exercises the same lookup the daemon's ids do. Truncated to the 16 bytes
  /// a real id carries; nothing here depends on the hash being hard to invert.
  static func previewProjectId(
    for identity: (source: TaskBoardProjectSource, slug: String)
  ) -> String {
    let seed = Data("\(identity.source.rawValue)/\(identity.slug)".utf8)
    let digest = SHA256.hash(data: seed)
    return "project-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  /// The daemon re-resolves attribution on every write, so a patch that moves
  /// the item to another project must not keep the project it came from.
  private func retainedSourceProjectId(
    after request: TaskBoardUpdateItemRequest
  ) -> String? {
    guard request.clearProjectId || request.projectId != nil else {
      return sourceProjectId
    }
    return nil
  }

  func applyingPreviewUpdate(_ request: TaskBoardUpdateItemRequest) -> TaskBoardItem {
    let updated = TaskBoardItem(
      schemaVersion: schemaVersion,
      id: id,
      title: request.title ?? title,
      body: request.body ?? body,
      status: request.status ?? status,
      priority: request.priority ?? priority,
      tags: request.tags ?? tags,
      projectId: request.clearProjectId ? nil : request.projectId ?? projectId,
      sourceProjectId: retainedSourceProjectId(after: request),
      targetProjectTypes: request.targetProjectTypes ?? targetProjectTypes,
      agentMode: request.agentMode ?? agentMode,
      externalRefs: previewExternalRefs(replacingWith: request.externalRefs),
      importedFromProvider: importedFromProvider,
      planning: request.clearPlanning
        ? TaskBoardPlanningState()
        : request.planning ?? planning,
      workflow: request.clearWorkflow ? nil : request.workflow ?? workflow,
      sessionId: request.clearSessionId ? nil : request.sessionId ?? sessionId,
      workItemId: request.clearWorkItemId ? nil : request.workItemId ?? workItemId,
      usage: usage,
      parentItemId: parentItemId,
      childOrder: childOrder,
      lanePosition: lanePosition,
      laneOrigin: laneOrigin,
      laneSetAt: laneSetAt,
      createdAt: createdAt,
      updatedAt: PreviewHarnessClientState.mutationTimestamp,
      deletedAt: deletedAt
    )
    return updated.applyingPreviewAttribution()
  }

  private func previewExternalRefs(
    replacingWith replacements: [TaskBoardExternalRef]?
  ) -> [TaskBoardExternalRef] {
    guard let replacements else {
      return externalRefs
    }
    return replacements.map { replacement in
      TaskBoardExternalRef(
        provider: replacement.provider,
        externalId: replacement.externalId,
        url: replacement.url,
        syncState: externalRefs.first(where: {
          $0.provider == replacement.provider && $0.externalId == replacement.externalId
        })?.syncState
      )
    }
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
