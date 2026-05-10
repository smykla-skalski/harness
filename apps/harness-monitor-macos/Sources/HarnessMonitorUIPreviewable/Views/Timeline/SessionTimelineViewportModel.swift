import Dispatch
import Observation
import SwiftUI

// Section body MUST NOT read this model. Reads belong to subtree consumers
// only (SessionTimelineNavigationControls). Reading from the section body
// would re-introduce the per-scroll body re-eval loop this model exists to
// break.
@MainActor
@Observable
final class SessionTimelineViewportModel {
  private static let observedViewportPublishIntervalNs: UInt64 = 120_000_000

  var visibleAnchorID: String?
  private(set) var visibilityStats: SessionTimelineVisibilityStats = .empty

  @ObservationIgnored private var lastViewport = SessionTimelineTableViewportStats.initial(
    estimatedVisibleEvents: 0
  )
  @ObservationIgnored private var latestVisibleAnchorID: String?
  @ObservationIgnored private var lastObservedViewportPublishTime: UInt64 = 0
  @ObservationIgnored private var pendingObservedViewportPublish: Task<Void, Never>?
  @ObservationIgnored private var presentationWindowStart = 0
  @ObservationIgnored private var presentationLoadedCount = 0
  @ObservationIgnored private var presentationTotalCount = 0
  @ObservationIgnored private var presentationFilteredMatchCount: Int?
  @ObservationIgnored private var lastScrollBoundaryState: SessionTimelineScrollBoundaryState?
  @ObservationIgnored private var hasObservedViewportStats = false

  func recordViewportStats(
    _ stats: SessionTimelineTableViewportStats,
    publishImmediately: Bool = false
  ) {
    hasObservedViewportStats = true
    lastViewport = stats
    if let anchorID = stats.anchorRowID {
      latestVisibleAnchorID = anchorID
    }
    guard !publishImmediately else {
      publishObservedViewportStats()
      return
    }
    publishObservedViewportStatsIfNeeded()
  }

  func recordScrollBoundaryState(_ state: SessionTimelineScrollBoundaryState) {
    lastScrollBoundaryState = state
  }

  func isNearTopScrollEdge() -> Bool {
    lastScrollBoundaryState?.isNearTopEdge ?? false
  }

  func isNearBottomScrollEdge() -> Bool {
    lastScrollBoundaryState?.isNearBottomEdge ?? false
  }

  func currentTopEdgeBufferDeficitRows() -> Int {
    lastScrollBoundaryState?.topEdgeBufferDeficitRows() ?? 0
  }

  func currentBottomEdgeBufferDeficitRows() -> Int {
    lastScrollBoundaryState?.bottomEdgeBufferDeficitRows() ?? 0
  }

  func currentVisibleAnchorID() -> String? {
    latestVisibleAnchorID ?? visibleAnchorID
  }

  func currentVisibleRowCount() -> Int {
    lastViewport.visibleRowCount
  }

  func currentViewportRowCapacity() -> Int {
    lastViewport.viewportRowCapacity
  }

  func currentFirstVisibleEventOffset() -> Int? {
    lastViewport.firstVisibleEventOffset
  }

  func currentLastVisibleEventOffset() -> Int? {
    lastViewport.lastVisibleEventOffset
  }

  func setAnchorID(_ id: String?) {
    latestVisibleAnchorID = id
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
    publishObservedViewportStats()
  }

  func recordInitialViewport(estimatedVisibleEvents: Int) {
    guard !hasObservedViewportStats else {
      return
    }
    let stats = SessionTimelineTableViewportStats.initial(
      estimatedVisibleEvents: min(max(estimatedVisibleEvents, 0), presentationLoadedCount)
    )
    lastViewport = stats
    latestVisibleAnchorID = stats.anchorRowID
    publishObservedViewportStats()
  }

  func clear() {
    pendingObservedViewportPublish?.cancel()
    pendingObservedViewportPublish = nil
    visibleAnchorID = nil
    latestVisibleAnchorID = nil
    visibilityStats = .empty
    lastViewport = SessionTimelineTableViewportStats.initial(
      estimatedVisibleEvents: 0
    )
    lastObservedViewportPublishTime = 0
    lastScrollBoundaryState = nil
    hasObservedViewportStats = false
    presentationWindowStart = 0
    presentationLoadedCount = 0
    presentationTotalCount = 0
    presentationFilteredMatchCount = nil
  }

  private func publishObservedViewportStatsIfNeeded() {
    let now = DispatchTime.now().uptimeNanoseconds
    guard lastObservedViewportPublishTime > 0 else {
      publishObservedViewportStats(now: now)
      return
    }
    let elapsed = now - lastObservedViewportPublishTime
    guard elapsed >= Self.observedViewportPublishIntervalNs else {
      scheduleObservedViewportPublish(after: Self.observedViewportPublishIntervalNs - elapsed)
      return
    }
    publishObservedViewportStats(now: now)
  }

  private func scheduleObservedViewportPublish(after delayNanoseconds: UInt64) {
    guard pendingObservedViewportPublish == nil else {
      return
    }
    pendingObservedViewportPublish = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: delayNanoseconds)
      guard let self, !Task.isCancelled else {
        return
      }
      self.pendingObservedViewportPublish = nil
      self.publishObservedViewportStats()
    }
  }

  private func publishObservedViewportStats() {
    publishObservedViewportStats(now: DispatchTime.now().uptimeNanoseconds)
  }

  private func publishObservedViewportStats(now: UInt64) {
    pendingObservedViewportPublish?.cancel()
    pendingObservedViewportPublish = nil
    lastObservedViewportPublishTime = now
    if visibleAnchorID != latestVisibleAnchorID {
      visibleAnchorID = latestVisibleAnchorID
    }
    rebuildStats()
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
