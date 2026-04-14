import Foundation

extension HarnessMonitorStore {
  func sessionDetailPreservingSelectedExtensions(
    sessionID: String,
    detail: SessionDetail,
    extensionsPending: Bool
  ) -> SessionDetail {
    guard extensionsPending,
      sessionID == selectedSessionID,
      let selectedSession
    else {
      return detail
    }

    return SessionDetail(
      session: detail.session,
      agents: detail.agents,
      tasks: detail.tasks,
      signals: selectedSession.signals,
      observer: selectedSession.observer,
      agentActivity: selectedSession.agentActivity
    )
  }

  func sessionDetailPreservingFresherSelectedSummary(
    sessionID: String,
    detail: SessionDetail
  ) -> SessionDetail {
    guard sessionID == selectedSessionID, let selectedSession else {
      return detail
    }

    let selectedSummary = selectedSession.session
    guard selectedSummary.sessionId == detail.session.sessionId else {
      return detail
    }

    guard
      selectedSummary.updatedAt > detail.session.updatedAt
        || selectedSummary.updatedAt == detail.session.updatedAt
          && selectedSummary != detail.session
    else {
      return detail
    }

    return SessionDetail(
      session: selectedSummary,
      agents: detail.agents,
      tasks: detail.tasks,
      signals: detail.signals,
      observer: detail.observer,
      agentActivity: detail.agentActivity
    )
  }

  func applySessionExtensions(_ extensions: SessionExtensionsPayload) {
    guard let sessionID = selectedSessionID,
      sessionID == extensions.sessionId
    else {
      return
    }

    cancelSelectedSessionRefreshFallback(for: sessionID)
    guard let detail = selectedSession else {
      pendingExtensions = extensions
      return
    }

    let merged = detail.merging(extensions: extensions)
    withUISyncBatch {
      selectedSession = merged
      isExtensionsLoading = false
      pendingExtensions = nil
    }

    let currentTimeline = timeline
    scheduleCacheWrite { service in
      await service.cacheSessionDetail(merged, timeline: currentTimeline)
    }
  }
}
