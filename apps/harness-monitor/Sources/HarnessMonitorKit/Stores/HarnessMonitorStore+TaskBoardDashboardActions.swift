import Foundation

extension HarnessMonitorStore {
  @discardableResult
  public func revokeTaskBoardPlan(
    id: String,
    actor: String? = nil
  ) async -> Bool {
    await mutateTaskBoardPlanning(actionName: "Revoked task board plan") { client in
      try await client.revokeTaskBoardPlan(
        id: id,
        request: TaskBoardPlanRevokeRequest(actor: actor)
      )
    }
  }

  /// Runs a dry-run evaluate and returns the resulting counts without
  /// mutating the persisted board state. Because `dry_run` makes no daemon
  /// changes, the caller renders the summary as a preview rather than
  /// overwriting the live evaluation summary or refreshing the dashboard.
  public func previewEvaluateTaskBoard(
    status: TaskBoardStatus? = nil,
    itemID: String? = nil
  ) async -> TaskBoardEvaluationSummary? {
    guard let client else {
      return nil
    }
    beginDaemonAction()
    defer { endDaemonAction() }

    do {
      let measuredSummary = try await Self.measureOperation {
        try await client.evaluateTaskBoard(
          request: TaskBoardEvaluateRequest(status: status, itemId: itemID, dryRun: true)
        )
      }
      recordRequestSuccess()
      presentSuccessFeedback("Previewed task board evaluate")
      return measuredSummary.value
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }
}
