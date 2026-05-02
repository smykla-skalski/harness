import Foundation

extension HarnessMonitorStore {
  public func requestWorkspaceSelection(_ selection: WorkspaceSelection) {
    pendingWorkspaceSelection = selection
  }

  public func requestWorkspaceDecisionSelection(decisionID: String) {
    requestWorkspaceSelection(
      .decision(
        sessionID: workspaceSessionID(forDecisionID: decisionID),
        decisionID: decisionID
      )
    )
  }

  public func consumePendingWorkspaceSelection() -> WorkspaceSelection? {
    let next = pendingWorkspaceSelection
    pendingWorkspaceSelection = nil
    return next
  }

  private func workspaceSessionID(forDecisionID decisionID: String) -> String? {
    if let sessionID =
      supervisorOpenDecisions
      .first(where: { $0.id == decisionID })?
      .sessionID
    {
      return normalizedWorkspaceSessionID(sessionID)
    }
    if let sessionID = acpPermissionDecisionPayload(for: decisionID)?.rawBatch.sessionId {
      return normalizedWorkspaceSessionID(sessionID)
    }
    return normalizedWorkspaceSessionID(selectedSessionID)
  }

  private func normalizedWorkspaceSessionID(_ sessionID: String?) -> String? {
    guard let sessionID else {
      return nil
    }
    let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
