import Foundation

extension HarnessMonitorStore {
  public func taskBoardTriageRulesDraft() async -> TaskBoardTriageRulesDraftResponse? {
    guard connectionState == .online, let client else { return nil }
    do {
      let measuredResponse = try await Self.measureOperation {
        try await client.taskBoardTriageRulesDraft()
      }
      recordRequestSuccess()
      return measuredResponse.value
    } catch is CancellationError {
      return nil
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }

  public func previewTaskBoardTriageRules(
    request: TaskBoardPreviewTriageRulesRequest
  ) async -> TriageRuleSetPreviewResult? {
    guard connectionState == .online, let client else { return nil }
    do {
      let measuredResponse = try await Self.measureOperation {
        try await client.previewTaskBoardTriageRules(request: request)
      }
      recordRequestSuccess()
      return measuredResponse.value
    } catch is CancellationError {
      return nil
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }

  public func taskBoardTriageRulesRevisions(limit: UInt32? = nil) async
    -> TaskBoardTriageRulesRevisionsResponse?
  {
    guard connectionState == .online, let client else { return nil }
    do {
      let measuredResponse = try await Self.measureOperation {
        try await client.taskBoardTriageRulesRevisions(limit: limit)
      }
      recordRequestSuccess()
      return measuredResponse.value
    } catch is CancellationError {
      return nil
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }

  public func taskBoardTriageRulesAudit(limit: UInt32? = nil) async
    -> TaskBoardTriageRulesAuditResponse?
  {
    guard connectionState == .online, let client else { return nil }
    do {
      let measuredResponse = try await Self.measureOperation {
        try await client.taskBoardTriageRulesAudit(limit: limit)
      }
      recordRequestSuccess()
      return measuredResponse.value
    } catch is CancellationError {
      return nil
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }

  @discardableResult
  public func saveTaskBoardTriageRulesDraft(
    rules: TriageRuleSetV1,
    expectedRevision: Int64?,
    actor: String = "Harness Monitor"
  ) async -> TriageRuleSetDraftSaveResult? {
    guard let client else { return nil }
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
      recordRequestSuccess()
      if result.persisted {
        presentSuccessFeedback("Save triage rules draft")
      }
      return result
    } catch {
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
    guard let client else { return nil }
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
      recordRequestSuccess()
      if result.activated {
        presentSuccessFeedback(rules == nil ? "Deactivate triage rules" : "Activate triage rules")
        await refreshTaskBoardDashboardSnapshot(using: client)
      }
      return result
    } catch {
      presentFailureFeedback(error.localizedDescription)
      await refreshTaskBoardDashboardSnapshot(using: client)
      return nil
    }
  }
}
