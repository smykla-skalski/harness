import Observation
import SwiftUI

// Section body MUST NOT read this model. Reads belong to subtree consumers
// only (SessionTimelineNavigationControls). Reading from the section body
// would re-introduce the per-scroll body re-eval loop this model exists to
// break.
@MainActor
@Observable
final class SessionTimelineViewportModel {
  var visibleAnchorID: String?
  private(set) var visibilityStats: SessionTimelineVisibilityStats = .empty

  @ObservationIgnored
  private var lastViewport = SessionTimelineTableViewportStats.initial(
    estimatedVisibleRows: 0,
    totalRows: 0
  )
  @ObservationIgnored
  private var presentationLoadedCount = 0
  @ObservationIgnored
  private var presentationTotalCount = 0

  func recordViewportStats(_ stats: SessionTimelineTableViewportStats) {
    lastViewport = stats
    if let anchorID = stats.anchorRowID, visibleAnchorID != anchorID {
      visibleAnchorID = anchorID
    }
    rebuildStats()
  }

  func setAnchorID(_ id: String?) {
    if visibleAnchorID != id {
      visibleAnchorID = id
    }
  }

  func updatePresentationCounts(loaded: Int, total: Int) {
    let clampedLoaded = max(0, loaded)
    let clampedTotal = max(0, total)
    guard
      presentationLoadedCount != clampedLoaded
        || presentationTotalCount != clampedTotal
    else {
      return
    }
    presentationLoadedCount = clampedLoaded
    presentationTotalCount = clampedTotal
    rebuildStats()
  }

  func recordInitialViewport(estimatedVisibleRows: Int, totalRows: Int) {
    let stats = SessionTimelineTableViewportStats.initial(
      estimatedVisibleRows: estimatedVisibleRows,
      totalRows: totalRows
    )
    recordViewportStats(stats)
  }

  func clear() {
    visibleAnchorID = nil
    visibilityStats = .empty
    lastViewport = SessionTimelineTableViewportStats.initial(
      estimatedVisibleRows: 0,
      totalRows: 0
    )
    presentationLoadedCount = 0
    presentationTotalCount = 0
  }

  private func rebuildStats() {
    let next = SessionTimelineVisibilityStats(
      visibleRowCount: lastViewport.visibleRowCount,
      renderedRowCount: lastViewport.renderedRowCount,
      loadedEventCount: presentationLoadedCount,
      totalEventCount: presentationTotalCount
    )
    if visibilityStats != next {
      visibilityStats = next
    }
  }
}
