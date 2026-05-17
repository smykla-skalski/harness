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

public enum SessionAgentRouteSelectionPolicy {
  public static func preferredRouteDetailAgentID(
    rememberedAgentID: String?,
    visibleAgentIDs: [String]
  ) -> String? {
    if let rememberedAgentID, visibleAgentIDs.contains(rememberedAgentID) {
      return rememberedAgentID
    }
    return visibleAgentIDs.first
  }
}

public enum SessionTaskRouteSelectionPolicy {
  public static func preferredRouteDetailTaskID(
    rememberedTaskID: String?,
    visibleTaskIDs: [String]
  ) -> String? {
    if let rememberedTaskID, visibleTaskIDs.contains(rememberedTaskID) {
      return rememberedTaskID
    }
    return visibleTaskIDs.first
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

  var decisionsRefreshTrigger: SessionDecisionDataKey {
    SessionDecisionDataKey(
      sessionID: token.sessionID,
      decisionIDs: store.supervisorOpenDecisionIDsBySession[token.sessionID] ?? []
    )
  }

  @MainActor var decisionFilterTrigger: SessionDecisionFilterSnapshot {
    SessionDecisionFilterSnapshot(filters: stateCache.decisionFilters)
  }
}
