import Foundation

extension HarnessMonitorStore {
  public struct PendingWorkspaceSelectionRequest: Equatable {
    public let selection: WorkspaceSelection
    public let resetDecisionFilters: Bool

    public init(selection: WorkspaceSelection, resetDecisionFilters: Bool) {
      self.selection = selection
      self.resetDecisionFilters = resetDecisionFilters
    }
  }

  public func requestWorkspaceSelection(
    _ selection: WorkspaceSelection,
    resetDecisionFilters: Bool = false
  ) {
    pendingWorkspaceSelection = selection
    pendingWorkspaceDecisionFilterResetRequested = resetDecisionFilters
  }

  public func requestWorkspaceDecisionSelection(
    decisionID: String,
    resetDecisionFilters: Bool = true
  ) {
    requestWorkspaceSelection(
      .decision(
        sessionID: workspaceSessionID(forDecisionID: decisionID),
        decisionID: decisionID
      ),
      resetDecisionFilters: resetDecisionFilters
    )
  }

  public func consumePendingWorkspaceSelection() -> WorkspaceSelection? {
    consumePendingWorkspaceSelectionRequest()?.selection
  }

  public func consumePendingWorkspaceSelectionRequest() -> PendingWorkspaceSelectionRequest? {
    guard let selection = pendingWorkspaceSelection else {
      pendingWorkspaceDecisionFilterResetRequested = false
      return nil
    }
    pendingWorkspaceSelection = nil
    let request = PendingWorkspaceSelectionRequest(
      selection: selection,
      resetDecisionFilters: pendingWorkspaceDecisionFilterResetRequested
    )
    pendingWorkspaceDecisionFilterResetRequested = false
    return request
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
