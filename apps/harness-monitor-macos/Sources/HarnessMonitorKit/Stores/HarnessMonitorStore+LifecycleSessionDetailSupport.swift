import Foundation

extension HarnessMonitorStore {
  func visiblePresentedSessionDetail(sessionID: String) -> SessionDetail? {
    guard sessionID == selectedSessionID else {
      return nil
    }

    if let selectedSession, selectedSession.session.sessionId == sessionID {
      return selectedSession
    }

    guard let presentedDetail = contentUI.sessionDetail.presentedSessionDetail,
      presentedDetail.session.sessionId == sessionID
    else {
      return nil
    }

    return presentedDetail
  }

  func visiblePresentedTimelineSnapshot(
    sessionID: String
  ) -> (timeline: [TimelineEntry], timelineWindow: TimelineWindowResponse?)? {
    guard sessionID == selectedSessionID else {
      return nil
    }

    if let selectedSession, selectedSession.session.sessionId == sessionID, !timeline.isEmpty {
      return (timeline, timelineWindow)
    }

    guard let presentedDetail = contentUI.sessionDetail.presentedSessionDetail,
      presentedDetail.session.sessionId == sessionID,
      !contentUI.sessionDetail.presentedTimeline.isEmpty
    else {
      return nil
    }

    return (
      contentUI.sessionDetail.presentedTimeline,
      contentUI.sessionDetail.presentedTimelineWindow
    )
  }

  func sessionDetailPreservingSelectedExtensions(
    sessionID: String,
    detail: SessionDetail,
    extensionsPending: Bool
  ) -> SessionDetail {
    guard extensionsPending,
      let visibleDetail = visiblePresentedSessionDetail(sessionID: sessionID)
    else {
      return detail
    }

    return SessionDetail(
      session: detail.session,
      agents: detail.agents,
      tasks: detail.tasks,
      signals: visibleDetail.signals,
      observer: visibleDetail.observer,
      agentActivity: visibleDetail.agentActivity
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
    let currentTimelineWindow = timelineWindow
    scheduleCacheWrite { service in
      await service.cacheSessionDetail(
        merged,
        timeline: currentTimeline,
        timelineWindow: currentTimelineWindow
      )
    }
  }
}
