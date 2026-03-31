import Foundation

extension HarnessStore {
  public func primeSessionSelection(_ sessionID: String?) {
    selectedSessionID = sessionID
    inspectorSelection = .none
    lastError = nil

    guard let sessionID else {
      activeSessionLoadRequest = 0
      isSelectionLoading = false
      selectedSession = nil
      timeline = []
      stopSessionStream()
      return
    }

    guard selectedSession?.session.sessionId != sessionID else {
      return
    }

    isSelectionLoading = true
    selectedSession = nil
    timeline = []
  }

  public func selectSession(_ sessionID: String?) async {
    let previousProjectId = selectedSessionSummary?.projectId
    primeSessionSelection(sessionID)
    guard let client, let sessionID else {
      stopSessionStream()
      return
    }

    let newProjectId = sessions.first(where: { $0.sessionId == sessionID })?.projectId
    if let previousProjectId, newProjectId != previousProjectId {
      saveFilterPreference(for: previousProjectId)
    }
    if let newProjectId, newProjectId != previousProjectId {
      loadFilterPreference(for: newProjectId)
    }

    let requestID = beginSessionLoad()
    await loadSession(using: client, sessionID: sessionID, requestID: requestID)
    guard isCurrentSessionLoad(requestID, sessionID: sessionID) else {
      return
    }
    startSessionStream(using: client, sessionID: sessionID)
  }

  public func inspect(taskID: String) {
    inspectorSelection = .task(taskID)
  }

  public func inspect(agentID: String) {
    inspectorSelection = .agent(agentID)
  }

  public func inspect(signalID: String) {
    inspectorSelection = .signal(signalID)
  }

  public func inspectObserver() {
    inspectorSelection = .observer
  }

  func synchronizeActionActor() {
    let available = availableActionActors
    if available.contains(where: { $0.agentId == actionActorID }) {
      return
    }
    actionActorID = selectedSession?.session.leaderId ?? available.first?.agentId
  }

  func resolvedActionActor() -> String? {
    if let actionActorID, !actionActorID.isEmpty {
      return actionActorID
    }
    if let leaderID = selectedSession?.session.leaderId, !leaderID.isEmpty {
      return leaderID
    }
    return availableActionActors.first?.agentId
  }

  func beginSessionLoad() -> UInt64 {
    sessionLoadSequence &+= 1
    activeSessionLoadRequest = sessionLoadSequence
    isSelectionLoading = true
    return sessionLoadSequence
  }

  func completeSessionLoad(_ requestID: UInt64) {
    guard activeSessionLoadRequest == requestID else {
      return
    }
    isSelectionLoading = false
  }

  func isCurrentSessionLoad(_ requestID: UInt64, sessionID: String) -> Bool {
    activeSessionLoadRequest == requestID && selectedSessionID == sessionID
  }
}
