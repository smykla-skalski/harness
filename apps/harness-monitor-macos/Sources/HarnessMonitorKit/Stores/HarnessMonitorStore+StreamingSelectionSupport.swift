import Foundation

extension HarnessMonitorStore {
  func refreshSelectedSessionIfSummaryChanged(sessions: [SessionSummary]) {
    guard let client,
      let selectedSessionID,
      let updatedSummary = sessions.first(where: { $0.sessionId == selectedSessionID }),
      selectedSession?.session != updatedSummary
    else {
      return
    }

    guard selectedSession != nil else {
      let requestID = beginSessionLoad()
      startSessionLoad(
        using: client,
        sessionID: selectedSessionID,
        requestID: requestID
      )
      return
    }

    applySelectedSessionSummaryUpdate(updatedSummary)
    scheduleSelectedSessionRefreshFallback(sessionID: selectedSessionID)
  }

  func applySelectedSessionSummaryUpdate(_ summary: SessionSummary) {
    applySessionSummaryUpdate(summary)
    guard let selectedSession,
      selectedSession.session.sessionId == summary.sessionId
    else {
      return
    }

    withUISyncBatch {
      self.selectedSession = SessionDetail(
        session: summary,
        agents: selectedSession.agents,
        tasks: selectedSession.tasks,
        signals: selectedSession.signals,
        observer: selectedSession.observer,
        agentActivity: selectedSession.agentActivity
      )
      synchronizeActionActor()
    }
  }

  func scheduleSelectedSessionRefreshFallback(sessionID: String) {
    selectedSessionRefreshFallbackSequence &+= 1
    let token = selectedSessionRefreshFallbackSequence
    pendingSelectedSessionRefreshFallback = (sessionID: sessionID, token: token)
    selectedSessionRefreshFallbackTask?.cancel()
    selectedSessionRefreshFallbackTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }
      defer {
        if self.pendingSelectedSessionRefreshFallback?.token == token {
          self.pendingSelectedSessionRefreshFallback = nil
          self.selectedSessionRefreshFallbackTask = nil
        }
      }
      do {
        try await Task.sleep(for: self.selectedSessionRefreshFallbackDelay)
      } catch {
        return
      }

      guard !Task.isCancelled,
        self.pendingSelectedSessionRefreshFallback?.sessionID == sessionID,
        self.pendingSelectedSessionRefreshFallback?.token == token,
        self.selectedSessionID == sessionID,
        self.selectedSession != nil,
        let client = self.client
      else {
        return
      }

      let requestID = self.activeSessionLoadRequest
      guard requestID != 0 else {
        return
      }

      self.pendingSelectedSessionRefreshFallback = nil
      self.selectedSessionRefreshFallbackTask = nil
      let loadTask = self.startSessionLoad(
        using: client,
        sessionID: sessionID,
        requestID: requestID
      )
      await loadTask.value
    }
  }

  func cancelSelectedSessionRefreshFallback(for sessionID: String? = nil) {
    guard
      sessionID == nil
        || pendingSelectedSessionRefreshFallback?.sessionID == sessionID
    else {
      return
    }

    pendingSelectedSessionRefreshFallback = nil
    selectedSessionRefreshFallbackTask?.cancel()
    selectedSessionRefreshFallbackTask = nil
  }
}
