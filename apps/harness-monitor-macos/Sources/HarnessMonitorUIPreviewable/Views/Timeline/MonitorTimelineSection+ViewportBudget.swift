import HarnessMonitorKit

extension SessionTimelineView {
  func preferredTimelineWindowLimit() -> Int {
    SessionTimelineWindowBudget.limit(
      forViewportRowCapacity: timelineViewport.currentViewportRowCapacity()
    )
  }

  func handleViewportStatsChange(
    _ stats: SessionTimelineTableViewportStats,
    presentation: SessionTimelineSectionPresentation
  ) {
    let preferredLimit = SessionTimelineWindowBudget.limit(
      forViewportRowCapacity: stats.viewportRowCapacity
    )
    store.updateSelectedTimelinePreferredWindowLimit(preferredLimit)
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
      await loadOlderTimelineChunk(limit: missingCount)
    }
  }
}
