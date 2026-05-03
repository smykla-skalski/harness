import Foundation

extension HarnessMonitorStore {
  public struct PendingWorkspaceSelectionRequest: Equatable {
    public let selection: WorkspaceSelection
    public let resetDecisionFilters: Bool
    public let createEntryPoint: WorkspaceCreateEntryPoint?

    public init(
      selection: WorkspaceSelection,
      resetDecisionFilters: Bool,
      createEntryPoint: WorkspaceCreateEntryPoint?
    ) {
      self.selection = selection
      self.resetDecisionFilters = resetDecisionFilters
      self.createEntryPoint = createEntryPoint
    }
  }

  public func requestWorkspaceSelection(
    _ selection: WorkspaceSelection,
    resetDecisionFilters: Bool = false,
    createEntryPoint: WorkspaceCreateEntryPoint? = nil
  ) {
    pendingWorkspaceSelection = selection
    pendingWorkspaceDecisionFilterResetRequested = resetDecisionFilters
    pendingWorkspaceCreateEntryPoint = createEntryPoint
  }

  public func requestWorkspaceCreateEntryPoint(_ entryPoint: WorkspaceCreateEntryPoint) {
    requestWorkspaceSelection(.create, createEntryPoint: entryPoint)
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
      pendingWorkspaceCreateEntryPoint = nil
      return nil
    }
    pendingWorkspaceSelection = nil
    let request = PendingWorkspaceSelectionRequest(
      selection: selection,
      resetDecisionFilters: pendingWorkspaceDecisionFilterResetRequested,
      createEntryPoint: pendingWorkspaceCreateEntryPoint
    )
    pendingWorkspaceDecisionFilterResetRequested = false
    pendingWorkspaceCreateEntryPoint = nil
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
