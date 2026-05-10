import HarnessMonitorKit

extension SessionTimelineView {
  func preferredTimelineWindowLimit() -> Int {
    SessionTimelineWindowBudget.limit(
      forViewportRowCapacity: timelineViewport.currentViewportRowCapacity()
    )
  }

  func retainedTimelineWindowLimit() -> Int {
    preferredTimelineWindowLimit()
  }

  func retainedTimelineWindowLimit(for action: SessionTimelineWindowAction) -> Int? {
    switch action {
    case .older, .newer:
      retainedTimelineWindowLimit()
    case .latest:
      nil
    }
  }

  // Stable method reference: presents the signal sheet without needing
  // a closure that captures store at body time.
  func handleSignalTap(_ signalID: String) {
    store.presentedSheet = .signalDetail(signalID: signalID)
  }

  // Reads cachedPresentation from @State so the table-view callbacks can
  // be assigned as stable method references; capturing a local presentation
  // value would force the closure identity to churn each parent body.
  func handleViewportStatsChange(_ stats: SessionTimelineTableViewportStats) {
    let preferredLimit = SessionTimelineWindowBudget.limit(
      forViewportRowCapacity: stats.viewportRowCapacity
    )
    store.updateSelectedTimelinePreferredWindowLimit(preferredLimit)
    let presentation = cachedPresentation
    guard presentation.hasLatestWindow,
      presentation.navigation.hasOlder,
      !isTimelineLoading
    else {
      return
    }
    let missingCount = preferredLimit - presentation.navigation.loadedCount
    guard missingCount > 0 else {
      return
    }
    Task {
      await loadOlderTimelineChunk(presentation: presentation, limit: missingCount)
    }
  }
}
