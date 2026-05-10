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

  func restorationAnchor(
    primary: SessionTimelineTableAnchor?,
    visibleAnchors: [SessionTimelineTableAnchor],
    nextRows: [SessionTimelineRow]
  ) -> SessionTimelineTableAnchor? {
    let nextIDs = Set(nextRows.map(\.id))
    if let primary, nextIDs.contains(primary.rowID) {
      return primary
    }
    let surviving = visibleAnchors.filter { nextIDs.contains($0.rowID) }
    switch self {
    case .older:
      return surviving.first
    case .newer:
      return surviving.last
    }
  }
}

extension SessionTimelineTableView.Coordinator {
  func currentVisibleAnchors() -> [SessionTimelineTableAnchor] {
    guard let tableView, let scrollView else {
      return []
    }
    let visibleRect = scrollView.contentView.bounds
    guard let visibleRange = visibleDataRowRange() else {
      return []
    }
    return visibleRange.map { rowIndex in
      guard let tableRow = tableRow(forDataIndex: rowIndex) else {
        return SessionTimelineTableAnchor(rowID: rows[rowIndex].id, offsetY: 0)
      }
      let rowRect = tableView.rect(ofRow: tableRow)
      return SessionTimelineTableAnchor(
        rowID: rows[rowIndex].id,
        offsetY: visibleRect.minY - virtualY(forTableRowMinY: rowRect.minY)
      )
    }
  }
}
