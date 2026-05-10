import HarnessMonitorKit

public enum SessionWindowFocusModePolicy {
  public static func usesRouteContent(selection: SessionSelection) -> Bool {
    selection.route != nil
  }
}

public enum SessionDecisionAutoSelectionPolicy {
  public static func preferredDecisionID(
    selection: SessionSelection,
    sessionID: String,
    allDecisionIDs: Set<String>,
    visibleDecisionIDs: [String]
  ) -> String? {
    guard let firstVisibleDecisionID = visibleDecisionIDs.first else {
      return nil
    }

    switch selection {
    case .decision(
      let selectedSessionID,
      let decisionID
    ) where selectedSessionID == sessionID && !allDecisionIDs.contains(decisionID):
      return firstVisibleDecisionID
    default:
      return nil
    }
  }

  public static func preferredRouteDetailDecisionID(
    rememberedDecisionID: String?,
    allDecisionIDs: Set<String>,
    visibleDecisionIDs: [String]
  ) -> String? {
    if let firstVisibleDecisionID = visibleDecisionIDs.first {
      if let rememberedDecisionID, visibleDecisionIDs.contains(rememberedDecisionID) {
        return rememberedDecisionID
      }
      return firstVisibleDecisionID
    }
    if let rememberedDecisionID, allDecisionIDs.contains(rememberedDecisionID) {
      return rememberedDecisionID
    }
    return nil
  }
}

extension SessionWindowView {
  func pendingUserPrompt(for agentID: String) -> AgentPendingUserPrompt? {
    guard
      let prompt = snapshot?.detail?.agentActivity
        .first(where: { $0.agentId == agentID })?
        .pendingUserPrompt,
      prompt.primaryQuestion != nil
    else {
      return nil
    }
    return prompt
  }

  var decisionsCacheTrigger: SessionDecisionFilterKey {
    SessionDecisionFilterKey(
      sessionID: token.sessionID,
      decisions: store.supervisorOpenDecisions.filter { $0.sessionID == token.sessionID },
      filters: stateCache.decisionFilters
    )
  }
}
