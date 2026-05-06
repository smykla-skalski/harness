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

  @ObservationIgnored private var lastViewport = SessionTimelineTableViewportStats.initial(
    estimatedVisibleEvents: 0
  )
  @ObservationIgnored private var presentationWindowStart = 0
  @ObservationIgnored private var presentationLoadedCount = 0
  @ObservationIgnored private var presentationTotalCount = 0
  @ObservationIgnored private var presentationFilteredMatchCount: Int?

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

  func updatePresentationCounts(
    windowStart: Int,
    loaded: Int,
    total: Int,
    filteredMatchCount: Int?
  ) {
    let clampedLoaded = max(0, loaded)
    let clampedTotal = max(0, total)
    let maximumWindowStart = max(0, clampedTotal - max(clampedLoaded, 1))
    let clampedWindowStart = max(0, min(windowStart, maximumWindowStart))
    let clampedFilteredMatchCount = filteredMatchCount.map { max(0, $0) }
    guard
      presentationWindowStart != clampedWindowStart
        || presentationLoadedCount != clampedLoaded
        || presentationTotalCount != clampedTotal
        || presentationFilteredMatchCount != clampedFilteredMatchCount
    else {
      return
    }
    presentationWindowStart = clampedWindowStart
    presentationLoadedCount = clampedLoaded
    presentationTotalCount = clampedTotal
    presentationFilteredMatchCount = clampedFilteredMatchCount
    rebuildStats()
  }

  func recordInitialViewport(estimatedVisibleEvents: Int) {
    let stats = SessionTimelineTableViewportStats.initial(
      estimatedVisibleEvents: min(max(estimatedVisibleEvents, 0), presentationLoadedCount)
    )
    recordViewportStats(stats)
  }

  func clear() {
    visibleAnchorID = nil
    visibilityStats = .empty
    lastViewport = SessionTimelineTableViewportStats.initial(
      estimatedVisibleEvents: 0
    )
    presentationWindowStart = 0
    presentationLoadedCount = 0
    presentationTotalCount = 0
    presentationFilteredMatchCount = nil
  }

  private func rebuildStats() {
    let next = SessionTimelineVisibilityStats(
      visibleRowCount: lastViewport.visibleRowCount,
      renderedRowCount: lastViewport.renderedRowCount,
      loadedEventCount: presentationLoadedCount,
      totalEventCount: presentationTotalCount,
      firstVisibleEventNumber: absoluteEventNumber(
        forLoadedOffset: lastViewport.firstVisibleEventOffset
      ),
      lastVisibleEventNumber: absoluteEventNumber(
        forLoadedOffset: lastViewport.lastVisibleEventOffset
      ),
      filteredMatchCount: presentationFilteredMatchCount,
      firstVisibleMatchNumber: visibleMatchNumber(
        forRowOffset: lastViewport.firstVisibleMatchOffset
      ),
      lastVisibleMatchNumber: visibleMatchNumber(
        forRowOffset: lastViewport.lastVisibleMatchOffset
      )
    )
    if visibilityStats != next {
      visibilityStats = next
    }
  }

  private func absoluteEventNumber(forLoadedOffset offset: Int?) -> Int? {
    guard
      let offset,
      presentationTotalCount > 0,
      presentationLoadedCount > 0
    else {
      return nil
    }
    let availableCount = min(
      presentationLoadedCount,
      max(0, presentationTotalCount - presentationWindowStart)
    )
    guard availableCount > 0 else {
      return nil
    }
    let clampedOffset = max(0, min(offset, availableCount - 1))
    return presentationWindowStart + clampedOffset + 1
  }

  private func visibleMatchNumber(forRowOffset offset: Int?) -> Int? {
    guard
      let offset,
      let presentationFilteredMatchCount,
      presentationFilteredMatchCount > 0
    else {
      return nil
    }
    let clampedOffset = max(0, min(offset, presentationFilteredMatchCount - 1))
    return clampedOffset + 1
  }
}
