import AppKit
import HarnessMonitorKit

enum SessionTimelineRollingRowChange: Equatable {
  case older
  case newer

  static func detect(
    previousRows: [SessionTimelineRow],
    nextRows: [SessionTimelineRow]
  ) -> Self? {
    detect(
      previousIDs: previousRows.map(\.id),
      nextIDs: nextRows.map(\.id)
    )
  }

  private static func detect(previousIDs: [String], nextIDs: [String]) -> Self? {
    guard previousIDs.count == nextIDs.count,
      previousIDs.count > 1,
      previousIDs != nextIDs
    else {
      return nil
    }

    if hasSuffixPrefixOverlap(
      suffixSource: previousIDs,
      prefixSource: nextIDs
    ) {
      return .older
    }
    if hasSuffixPrefixOverlap(
      suffixSource: nextIDs,
      prefixSource: previousIDs
    ) {
      return .newer
    }
    return nil
  }

  private static func hasSuffixPrefixOverlap(
    suffixSource: [String],
    prefixSource: [String]
  ) -> Bool {
    guard let overlapStart = suffixSource.firstIndex(of: prefixSource[0]),
      overlapStart > 0
    else {
      return false
    }
    let overlapCount = suffixSource.count - overlapStart
    guard overlapCount > 0 else {
      return false
    }
    return Array(suffixSource[overlapStart...])
      == Array(prefixSource[..<overlapCount])
  }
}

extension SessionTimelineTableView.Coordinator {
  func currentScrollY() -> CGFloat? {
    scrollView?.contentView.bounds.minY
  }

  func restoreScrollY(_ scrollY: CGFloat) {
    guard let scrollView else {
      return
    }
    tableView?.layoutSubtreeIfNeeded()
    scrollView.layoutSubtreeIfNeeded()
    let restoredY = clampedScrollY(scrollY, scrollView: scrollView)
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: restoredY))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    syncBoundaryStateToCurrentViewport()
    boundsDidChange(forceObservedStats: true)
  }
}
