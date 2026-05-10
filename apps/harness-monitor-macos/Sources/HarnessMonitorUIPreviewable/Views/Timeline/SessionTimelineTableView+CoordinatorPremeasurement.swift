import AppKit
import HarnessMonitorKit

extension SessionTimelineTableView.Coordinator {
  func prepareColumnForRowReload(columnWidth: CGFloat) {
    guard columnWidth > 1 else {
      return
    }
    if let column = tableView?.tableColumns.first, column.width != columnWidth {
      column.width = columnWidth
    }
    lastColumnWidth = columnWidth
  }

  func premeasureRowsBeforeReload(
    rows nextRows: [SessionTimelineRow],
    priorIDs: Set<String>,
    invalidatedHeightIDs: Set<String>,
    restorationAnchorID: String?,
    columnWidth: CGFloat
  ) {
    guard columnWidth > 1, !nextRows.isEmpty else {
      return
    }
    var indexes: [Int] = []
    var seen = Set<Int>()
    appendViewportPremeasurementIndexes(to: &indexes, seen: &seen, rowCount: nextRows.count)
    appendAnchorInfluencingIndexes(
      to: &indexes,
      seen: &seen,
      rows: nextRows,
      priorIDs: priorIDs,
      invalidatedHeightIDs: invalidatedHeightIDs,
      restorationAnchorID: restorationAnchorID
    )
    guard !indexes.isEmpty else {
      return
    }
    var measuredCount = 0
    autoreleasepool {
      for index in indexes {
        guard nextRows.indices.contains(index) else { continue }
        let row = nextRows[index]
        guard rowRequiresMeasurement(row, columnWidth: columnWidth) else {
          continue
        }
        cacheMeasuredHeight(for: row, columnWidth: columnWidth)
        measuredCount += 1
      }
    }
    if measuredCount > 0 {
      let width = Int(columnWidth)
      Self.signposter.emitEvent(
        "session_timeline.measurement.preload",
        "m=\(measuredCount, privacy: .public) w=\(width, privacy: .public)"
      )
    }
  }

  private func appendViewportPremeasurementIndexes(
    to indexes: inout [Int],
    seen: inout Set<Int>,
    rowCount: Int
  ) {
    for index in Self.orderedMeasurementIndexes(
      rowCount: rowCount,
      visibleRange: projectedVisibleRangeForPremeasurement(rowCount: rowCount),
      mode: .incremental
    ) {
      appendPremeasurementIndex(index, to: &indexes, seen: &seen, rowCount: rowCount)
    }
  }

  private func appendAnchorInfluencingIndexes(
    to indexes: inout [Int],
    seen: inout Set<Int>,
    rows nextRows: [SessionTimelineRow],
    priorIDs: Set<String>,
    invalidatedHeightIDs: Set<String>,
    restorationAnchorID: String?
  ) {
    guard
      let restorationAnchorID,
      let anchorIndex = nextRows.firstIndex(where: { $0.id == restorationAnchorID })
    else {
      return
    }
    for index in 0...anchorIndex {
      let row = nextRows[index]
      guard !priorIDs.contains(row.id) || invalidatedHeightIDs.contains(row.id) else {
        continue
      }
      appendPremeasurementIndex(index, to: &indexes, seen: &seen, rowCount: nextRows.count)
    }
  }

  private func projectedVisibleRangeForPremeasurement(rowCount: Int) -> Range<Int>? {
    guard rowCount > 0 else {
      return nil
    }
    if let currentRange = visibleRowIndexRange() {
      let lowerBound = min(max(0, currentRange.lowerBound), rowCount - 1)
      let upperBound = min(rowCount, max(lowerBound + 1, currentRange.upperBound))
      return lowerBound..<upperBound
    }
    let viewportHeight =
      scrollView?.contentSize.height ?? scrollView?.contentView.bounds.height ?? 0
    guard viewportHeight > 1 else {
      return 0..<rowCount
    }
    let estimatedRows = Int(
      ceil(viewportHeight / max(1, SessionTimelineSectionPresentation.rowHeightEstimate))
    )
    return 0..<min(rowCount, max(1, estimatedRows))
  }

  private func appendPremeasurementIndex(
    _ index: Int,
    to indexes: inout [Int],
    seen: inout Set<Int>,
    rowCount: Int
  ) {
    guard index >= 0, index < rowCount, seen.insert(index).inserted else {
      return
    }
    indexes.append(index)
  }
}
