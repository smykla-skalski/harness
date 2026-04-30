import Foundation

extension HarnessMonitorStore {
  var readOnlySessionAccessMessage: String {
    """
    The harness daemon is offline. Persisted session data is available in
    read-only mode until live connection returns.
    """
  }

  private var actionChannelUnavailableMessage: String {
    "The daemon action channel is unavailable. Refresh the session and try again."
  }

  private var noSelectedSessionActionMessage: String {
    "No session is selected. Choose a session and try again."
  }

  var noResolvedActionActorMessage: String {
    "No session actor is available yet. Wait for a leader or active agent to join, then try again."
  }

  private var noSelectedLeaderMessage: String {
    """
    Leader-only actions are unavailable until a real leader joins this session.
    Observe, end session, and task controls remain available.
    """
  }

  public var selectedSessionActionUnavailableMessage: String? {
    if isSessionReadOnly {
      return readOnlySessionAccessMessage
    }
    if selectedSessionID == nil {
      return noSelectedSessionActionMessage
    }
    if client == nil {
      return actionChannelUnavailableMessage
    }
    return nil
  }

  public var areSelectedSessionActionsAvailable: Bool {
    selectedSessionActionUnavailableMessage == nil
  }

  public var selectedLeaderActionUnavailableMessage: String? {
    if let generalUnavailableMessage = selectedSessionActionUnavailableMessage {
      return generalUnavailableMessage
    }
    guard selectedSessionHasRealLeader else {
      return noSelectedLeaderMessage
    }
    if resolvedActionActor() == nil {
      return noResolvedActionActorMessage
    }
    return nil
  }

  public var areSelectedLeaderActionsAvailable: Bool {
    selectedLeaderActionUnavailableMessage == nil
  }

  public var selectedSessionActionBannerMessage: String? {
    selectedLeaderActionUnavailableMessage ?? selectedSessionActionUnavailableMessage
  }

  func guardSessionActionsAvailable(actionName: String = "Session action") -> Bool {
    guard let unavailableMessage = selectedSessionActionUnavailableMessage else {
      return true
    }
    reportUnavailableSelectedSessionAction(actionName, message: unavailableMessage)
    return false
  }

  func guardLeaderActionsAvailable(actionName: String = "Session action") -> Bool {
    guard let unavailableMessage = selectedLeaderActionUnavailableMessage else {
      return true
    }
    reportUnavailableSelectedSessionAction(actionName, message: unavailableMessage)
    return false
  }

  func reportUnavailableSelectedSessionAction(
    _ actionName: String,
    message: String
  ) {
    let sessionID = selectedSessionID ?? "none"
    let leaderID = selectedSession?.session.leaderId ?? "none"
    let actorID = actionActorID ?? "none"
    let activeActors = availableActionActors.map(\.agentId).joined(separator: ",")
    HarnessMonitorLogger.store.warning(
      """
      Session action unavailable: \(actionName, privacy: .public); reason=\
      \(message, privacy: .public); sessionID=\(sessionID, privacy: .public); \
      leaderID=\(leaderID, privacy: .public); actorID=\(actorID, privacy: .public); \
      activeActors=\(activeActors, privacy: .public)
      """
    )
    presentFailureFeedback(message)
  }

  func prepareSelectedSessionAction(
    named actionName: String
  ) -> (client: any HarnessMonitorClientProtocol, sessionID: String)? {
    if isSessionReadOnly {
      reportUnavailableSelectedSessionAction(actionName, message: readOnlySessionAccessMessage)
      return nil
    }
    guard let sessionID = selectedSessionID else {
      reportUnavailableSelectedSessionAction(actionName, message: noSelectedSessionActionMessage)
      return nil
    }
    guard let client else {
      reportUnavailableSelectedSessionAction(actionName, message: actionChannelUnavailableMessage)
      return nil
    }
    return (client, sessionID)
  }

  func prepareSessionAction(
    named actionName: String,
    sessionID: String
  ) -> (client: any HarnessMonitorClientProtocol, sessionID: String)? {
    if isSessionReadOnly {
      reportUnavailableSelectedSessionAction(actionName, message: readOnlySessionAccessMessage)
      return nil
    }
    guard !sessionID.isEmpty else {
      reportUnavailableSelectedSessionAction(actionName, message: noSelectedSessionActionMessage)
      return nil
    }
    guard let client else {
      reportUnavailableSelectedSessionAction(actionName, message: actionChannelUnavailableMessage)
      return nil
    }
    return (client, sessionID)
  }

  private var selectedSessionHasRealLeader: Bool {
    guard let detail = selectedSession else {
      return false
    }
    guard let leaderID = detail.session.leaderId else {
      return false
    }
    return detail.agents.contains { $0.agentId == leaderID }
  }
}
