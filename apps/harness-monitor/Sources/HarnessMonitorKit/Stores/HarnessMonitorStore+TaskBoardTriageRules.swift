import Foundation

extension HarnessMonitorStore {
  public func taskBoardTriageRulesDraft() async -> TaskBoardTriageRulesDraftResponse? {
    await readTaskBoard { client in
      try await client.taskBoardTriageRulesDraft()
    }
  }

  public func previewTaskBoardTriageRules(
    request: TaskBoardPreviewTriageRulesRequest
  ) async -> TriageRuleSetPreviewResult? {
    await readTaskBoard { client in
      try await client.previewTaskBoardTriageRules(request: request)
    }
  }

  public func taskBoardTriageRulesRevisions(limit: UInt32? = nil) async
    -> TaskBoardTriageRulesRevisionsResponse?
  {
    await readTaskBoard { client in
      try await client.taskBoardTriageRulesRevisions(limit: limit)
    }
  }

  public func taskBoardTriageRulesAudit(limit: UInt32? = nil) async
    -> TaskBoardTriageRulesAuditResponse?
  {
    await readTaskBoard { client in
      try await client.taskBoardTriageRulesAudit(limit: limit)
    }
  }

  @discardableResult
  public func saveTaskBoardTriageRulesDraft(
    rules: TriageRuleSetV1,
    expectedRevision: Int64?,
    actor: String = "Harness Monitor"
  ) async -> TriageRuleSetDraftSaveResult? {
    guard let access = availableTaskBoardClientAccess else { return nil }
    let client = access.client
    beginDaemonAction()
    beginTaskBoardAction()
    defer {
      endDaemonAction()
      endTaskBoardAction()
    }
    do {
      let request = TaskBoardSaveTriageRulesDraftRequest(
        rules: rules,
        expectedRevision: expectedRevision,
        actor: actor
      )
      let result = try await Self.measureOperation {
        try await client.saveTaskBoardTriageRulesDraft(request: request)
      }.value
      try requireCurrentTaskBoardClientAccess(access)
      recordRequestSuccess()
      if result.persisted {
        presentSuccessFeedback("Save triage rules draft")
      }
      return result
    } catch is CancellationError {
      return nil
    } catch {
      guard taskBoardAccessIsCurrent(access) else { return nil }
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }

  @discardableResult
  public func activateTaskBoardTriageRules(
    rules: TriageRuleSetV1?,
    expectedActiveRevision: Int64?,
    actor: String = "Harness Monitor"
  ) async -> TriageRuleSetActivationResult? {
    guard let access = availableTaskBoardClientAccess else { return nil }
    let client = access.client
    beginDaemonAction()
    beginTaskBoardAction()
    defer {
      endDaemonAction()
      endTaskBoardAction()
    }
    do {
      let request = TaskBoardActivateTriageRulesRequest(
        rules: rules,
        expectedActiveRevision: expectedActiveRevision,
        actor: actor
      )
      let result = try await Self.measureOperation {
        try await client.activateTaskBoardTriageRules(request: request)
      }.value
      try requireCurrentTaskBoardClientAccess(access)
      recordRequestSuccess()
      if result.activated {
        presentSuccessFeedback(rules == nil ? "Deactivate triage rules" : "Activate triage rules")
        await refreshTaskBoardDashboardSnapshot(using: client, access: access)
      }
      return result
    } catch is CancellationError {
      return nil
    } catch {
      guard taskBoardAccessIsCurrent(access) else { return nil }
      presentFailureFeedback(error.localizedDescription)
      await refreshTaskBoardDashboardSnapshot(using: client, access: access)
      return nil
    }
  }
}
