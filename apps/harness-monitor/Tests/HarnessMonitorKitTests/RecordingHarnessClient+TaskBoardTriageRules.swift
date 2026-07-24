import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func taskBoardTriageRulesDraft() async throws -> TaskBoardTriageRulesDraftResponse {
    lock.withLock {
      TaskBoardTriageRulesDraftResponse(draft: taskBoardTriageRuleSetDraftStorage)
    }
  }

  func saveTaskBoardTriageRulesDraft(
    request: TaskBoardSaveTriageRulesDraftRequest
  ) async throws -> TriageRuleSetDraftSaveResult {
    try lock.withLock {
      taskBoardTriageRulesSaveDraftRequests.append(request)
      try throwQueuedTriageRulesErrorIfNeeded()
      guard taskBoardTriageRuleSetDraftStorage?.revision == request.expectedRevision else {
        return TriageRuleSetDraftSaveResult(
          validation: TriageRuleSetValidationReport(),
          persisted: false,
          revision: taskBoardTriageRuleSetDraftStorage?.revision
        )
      }
      let nextRevision = (request.expectedRevision ?? 0) + 1
      taskBoardTriageRuleSetDraftStorage = TriageRuleSetDraft(
        rules: request.rules,
        revision: nextRevision,
        actor: request.actor,
        updatedAt: "2026-07-24T00:00:00Z"
      )
      return TriageRuleSetDraftSaveResult(
        validation: TriageRuleSetValidationReport(),
        persisted: true,
        revision: nextRevision
      )
    }
  }

  func previewTaskBoardTriageRules(
    request: TaskBoardPreviewTriageRulesRequest
  ) async throws -> TriageRuleSetPreviewResult {
    lock.withLock {
      let diff = taskBoardItemsStorage.map { item in
        TriageRuleSetPreviewDiffEntry(
          itemId: item.id,
          candidateVerdict: request.rules.defaultOutcome.verdict,
          governsPlacementChange: false
        )
      }
      return TriageRuleSetPreviewResult(validation: TriageRuleSetValidationReport(), diff: diff)
    }
  }

  func activateTaskBoardTriageRules(
    request: TaskBoardActivateTriageRulesRequest
  ) async throws -> TriageRuleSetActivationResult {
    try lock.withLock {
      taskBoardTriageRulesActivateRequests.append(request)
      try throwQueuedTriageRulesErrorIfNeeded()
      guard taskBoardActiveTriageRuleSetRevisionStorage == request.expectedActiveRevision else {
        return TriageRuleSetActivationResult(
          validation: TriageRuleSetValidationReport(),
          activated: false,
          revision: taskBoardActiveTriageRuleSetRevisionStorage,
          reevaluatedItemCount: 0
        )
      }
      if let previousRevision = taskBoardActiveTriageRuleSetRevisionStorage,
        let index = taskBoardTriageRuleSetRevisionsStorage.firstIndex(where: {
          $0.revision == previousRevision
        })
      {
        let previous = taskBoardTriageRuleSetRevisionsStorage[index]
        taskBoardTriageRuleSetRevisionsStorage[index] = TriageRuleSetRevisionSummary(
          revision: previous.revision,
          schemaVersion: previous.schemaVersion,
          ruleCount: previous.ruleCount,
          status: .superseded,
          actor: previous.actor,
          activatedAt: previous.activatedAt,
          supersededAt: "2026-07-24T00:00:00Z"
        )
      }
      let newRevision = request.rules.map { _ in
        (taskBoardTriageRuleSetRevisionsStorage.map(\.revision).max() ?? 0) + 1
      }
      if let rules = request.rules, let newRevision {
        taskBoardTriageRuleSetRevisionsStorage.append(
          TriageRuleSetRevisionSummary(
            revision: newRevision,
            schemaVersion: rules.schemaVersion,
            ruleCount: UInt(rules.rules.count),
            status: .active,
            actor: request.actor,
            activatedAt: "2026-07-24T00:00:00Z",
            supersededAt: nil
          )
        )
      }
      taskBoardActiveTriageRuleSetRevisionStorage = newRevision
      taskBoardTriageRuleSetAuditStorage.insert(
        TriageRuleSetAuditEntry(
          auditId: "recording-audit-\(taskBoardTriageRuleSetAuditStorage.count)",
          kind: request.rules == nil ? .deactivated : .activated,
          revision: newRevision,
          actor: request.actor,
          reevaluatedItemCount: Int64(taskBoardItemsStorage.count),
          recordedAt: "2026-07-24T00:00:00Z"
        ),
        at: 0
      )
      return TriageRuleSetActivationResult(
        validation: TriageRuleSetValidationReport(),
        activated: true,
        revision: newRevision,
        reevaluatedItemCount: UInt(taskBoardItemsStorage.count)
      )
    }
  }

  func taskBoardTriageRulesRevisions(limit: UInt32?) async throws
    -> TaskBoardTriageRulesRevisionsResponse
  {
    lock.withLock {
      let sorted = taskBoardTriageRuleSetRevisionsStorage.sorted { $0.revision > $1.revision }
      return TaskBoardTriageRulesRevisionsResponse(
        revisions: Array(sorted.prefix(Int(limit ?? 50))))
    }
  }

  func taskBoardTriageRulesAudit(limit: UInt32?) async throws -> TaskBoardTriageRulesAuditResponse {
    lock.withLock {
      TaskBoardTriageRulesAuditResponse(
        audit: Array(taskBoardTriageRuleSetAuditStorage.prefix(Int(limit ?? 50)))
      )
    }
  }

  private func throwQueuedTriageRulesErrorIfNeeded() throws {
    guard taskBoardTriageRulesErrorRemainingUses > 0, let error = taskBoardTriageRulesError else {
      return
    }
    taskBoardTriageRulesErrorRemainingUses -= 1
    throw error
  }
}
