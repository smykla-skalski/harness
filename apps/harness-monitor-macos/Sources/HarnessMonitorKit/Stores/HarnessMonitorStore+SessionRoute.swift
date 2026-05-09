import Foundation

extension HarnessMonitorStore {
  public struct PendingSessionRouteRequest: Equatable {
    public let selection: SessionRouteSelection
    public let resetDecisionFilters: Bool
    public let createEntryPoint: SessionRouteCreateEntryPoint?
    public let createSessionID: String?

    public init(
      selection: SessionRouteSelection,
      resetDecisionFilters: Bool,
      createEntryPoint: SessionRouteCreateEntryPoint?,
      createSessionID: String?
    ) {
      self.selection = selection
      self.resetDecisionFilters = resetDecisionFilters
      self.createEntryPoint = createEntryPoint
      self.createSessionID = createSessionID
    }
  }

  public func requestSessionRoute(
    _ selection: SessionRouteSelection,
    resetDecisionFilters: Bool = false,
    createEntryPoint: SessionRouteCreateEntryPoint? = nil,
    createSessionID: String? = nil
  ) {
    pendingSessionRoute = selection
    pendingSessionRouteDecisionFilterReset = resetDecisionFilters
    pendingSessionRouteCreateEntryPoint = createEntryPoint
    pendingSessionRouteCreateSessionID = normalizedWorkspaceSessionID(createSessionID)
  }

  public func requestSessionRouteCreate(
    _ entryPoint: SessionRouteCreateEntryPoint,
    sessionID: String? = nil
  ) {
    requestSessionRoute(
      .create,
      createEntryPoint: entryPoint,
      createSessionID: normalizedWorkspaceSessionID(sessionID)
        ?? preferredWorkspaceCreateSessionID()
    )
  }

  private func preferredWorkspaceCreateSessionID() -> String? {
    if isShowingCachedCatalog {
      return normalizedWorkspaceSessionID(selectedSession?.session.sessionId)
    }
    return normalizedWorkspaceSessionID(selectedSession?.session.sessionId)
      ?? normalizedWorkspaceSessionID(selectedSessionSummary?.sessionId)
  }

  public func requestSessionDecisionRoute(
    decisionID: String,
    resetDecisionFilters: Bool = true
  ) {
    requestSessionRoute(
      .decision(
        sessionID: workspaceSessionID(forDecisionID: decisionID),
        decisionID: decisionID
      ),
      resetDecisionFilters: resetDecisionFilters
    )
  }

  public func consumePendingSessionRoute() -> SessionRouteSelection? {
    consumePendingSessionRouteRequest()?.selection
  }

  public func consumePendingSessionRouteRequest() -> PendingSessionRouteRequest? {
    guard let selection = pendingSessionRoute else {
      pendingSessionRouteDecisionFilterReset = false
      pendingSessionRouteCreateEntryPoint = nil
      pendingSessionRouteCreateSessionID = nil
      return nil
    }
    pendingSessionRoute = nil
    let request = PendingSessionRouteRequest(
      selection: selection,
      resetDecisionFilters: pendingSessionRouteDecisionFilterReset,
      createEntryPoint: pendingSessionRouteCreateEntryPoint,
      createSessionID: pendingSessionRouteCreateSessionID
    )
    pendingSessionRouteDecisionFilterReset = false
    pendingSessionRouteCreateEntryPoint = nil
    pendingSessionRouteCreateSessionID = nil
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
