import SwiftUI

struct SessionTimelineVirtualizedLayout: Equatable {
  private static let minimumBufferRows = 4
  private static let maximumBufferRows = 8

  let rows: [SessionTimelineRow]
  let topSpacerHeight: CGFloat
  let bottomSpacerHeight: CGFloat
  let renderedRowIDs: Set<String>
  let estimatedVisibleRowCount: Int
  let totalRowCount: Int

  var renderedRowCount: Int {
    rows.count
  }

  static let empty = Self(
    rows: [],
    topSpacerHeight: 0,
    bottomSpacerHeight: 0,
    renderedRowIDs: [],
    estimatedVisibleRowCount: 0,
    totalRowCount: 0
  )

  init(
    rows: [SessionTimelineRow],
    topSpacerHeight: CGFloat,
    bottomSpacerHeight: CGFloat,
    renderedRowIDs: Set<String>,
    estimatedVisibleRowCount: Int,
    totalRowCount: Int
  ) {
    self.rows = rows
    self.topSpacerHeight = topSpacerHeight
    self.bottomSpacerHeight = bottomSpacerHeight
    self.renderedRowIDs = renderedRowIDs
    self.estimatedVisibleRowCount = max(0, estimatedVisibleRowCount)
    self.totalRowCount = max(0, totalRowCount)
  }

  init(
    rows allRows: [SessionTimelineRow],
    rowHeights: [String: CGFloat],
    scrollMetrics: SessionTimelineScrollMetrics,
    fallbackViewportHeight: CGFloat,
    pinnedRowID: String?
  ) {
    guard !allRows.isEmpty else {
      self = .empty
      return
    }

    let metrics = Self.makeMetrics(for: allRows, rowHeights: rowHeights)
    let viewportHeight = Self.resolvedViewportHeight(
      scrollMetrics: scrollMetrics,
      fallbackViewportHeight: fallbackViewportHeight
    )
    let visibleRange = Self.visibleRange(
      metrics: metrics,
      scrollMetrics: scrollMetrics,
      viewportHeight: viewportHeight
    )
    let bufferRows = Self.bufferRowCount(viewportHeight: viewportHeight)
    var renderRange = Self.bufferedRange(
      visibleRange: visibleRange,
      bufferRows: bufferRows,
      totalCount: allRows.count
    )

    if let pinnedRowID,
      let pinnedIndex = allRows.firstIndex(where: { $0.id == pinnedRowID }),
      !renderRange.contains(pinnedIndex)
    {
      renderRange = Self.pinnedRange(
        pinnedIndex: pinnedIndex,
        visibleRange: visibleRange,
        bufferRows: bufferRows,
        totalCount: allRows.count
      )
    }

    let renderedRows = Array(allRows[renderRange])
    let renderedRowIDs = Set(renderedRows.map(\.id))

    self.init(
      rows: renderedRows,
      topSpacerHeight: Self.topSpacerHeight(
        startIndex: renderRange.lowerBound,
        metrics: metrics
      ),
      bottomSpacerHeight: Self.bottomSpacerHeight(
        endIndex: renderRange.upperBound,
        metrics: metrics
      ),
      renderedRowIDs: renderedRowIDs,
      estimatedVisibleRowCount: visibleRange.count,
      totalRowCount: allRows.count
    )
  }

  private static func makeMetrics(
    for rows: [SessionTimelineRow],
    rowHeights: [String: CGFloat]
  ) -> SessionTimelineLayoutMetrics {
    var measuredRows: [SessionTimelineMeasuredRow] = []
    measuredRows.reserveCapacity(rows.count)

    var cursor: CGFloat = 0
    for (index, row) in rows.enumerated() {
      if index > 0 {
        cursor += HarnessMonitorTheme.itemSpacing
      }
      let height = sanitizedHeight(rowHeights[row.id]) ?? estimatedHeight(for: row)
      measuredRows.append(
        SessionTimelineMeasuredRow(
          index: index,
          id: row.id,
          top: cursor,
          height: height
        )
      )
      cursor += height
    }

    return SessionTimelineLayoutMetrics(rows: measuredRows, contentHeight: cursor)
  }

  private static func sanitizedHeight(_ height: CGFloat?) -> CGFloat? {
    guard let height, height.isFinite, height > 0 else {
      return nil
    }
    return height
  }

  private static func estimatedHeight(for row: SessionTimelineRow) -> CGFloat {
    var estimate = SessionTimelineSectionPresentation.rowHeightEstimate
    if row.dayDividerLabel != nil {
      estimate += 28
    }
    if row.node.detail != nil {
      estimate += 18
    }
    if !row.node.actions.isEmpty {
      estimate += 34
    }
    return estimate
  }

  private static func resolvedViewportHeight(
    scrollMetrics: SessionTimelineScrollMetrics,
    fallbackViewportHeight: CGFloat
  ) -> CGFloat {
    let measuredHeight = scrollMetrics.viewportHeight
    if measuredHeight.isFinite, measuredHeight > 0 {
      return measuredHeight
    }
    guard fallbackViewportHeight.isFinite, fallbackViewportHeight > 0 else {
      return SessionTimelineSectionPresentation.rowHeightEstimate
    }
    return fallbackViewportHeight
  }

  private static func visibleRange(
    metrics: SessionTimelineLayoutMetrics,
    scrollMetrics: SessionTimelineScrollMetrics,
    viewportHeight: CGFloat
  ) -> Range<Int> {
    let visibleRect = scrollMetrics.visibleRect
    let visibleMinY =
      visibleRect.isEmpty ? max(0, scrollMetrics.contentOffsetY) : max(0, visibleRect.minY)
    let visibleMaxY =
      visibleRect.isEmpty
      ? visibleMinY + viewportHeight
      : max(visibleMinY + 1, visibleRect.maxY)

    guard let firstVisibleIndex = metrics.rows.first(where: { $0.bottom >= visibleMinY })?.index
    else {
      let lastIndex = max(metrics.rows.count - 1, 0)
      return lastIndex..<(lastIndex + 1)
    }

    let lastVisibleIndex =
      metrics.rows.last(where: { $0.top <= visibleMaxY })?.index
      ?? firstVisibleIndex
    return firstVisibleIndex..<(lastVisibleIndex + 1)
  }

  private static func bufferRowCount(viewportHeight: CGFloat) -> Int {
    let estimatedVisibleRows = Int(
      (viewportHeight / SessionTimelineSectionPresentation.rowHeightEstimate).rounded(.up)
    )
    return min(max(estimatedVisibleRows, minimumBufferRows), maximumBufferRows)
  }

  private static func bufferedRange(
    visibleRange: Range<Int>,
    bufferRows: Int,
    totalCount: Int
  ) -> Range<Int> {
    let startIndex = max(0, visibleRange.lowerBound - bufferRows)
    let endIndex = min(totalCount, visibleRange.upperBound + bufferRows)
    return startIndex..<max(startIndex + 1, endIndex)
  }

  private static func pinnedRange(
    pinnedIndex: Int,
    visibleRange: Range<Int>,
    bufferRows: Int,
    totalCount: Int
  ) -> Range<Int> {
    let visibleCount = max(1, visibleRange.count)
    let leadingRows = max(bufferRows, visibleCount / 2)
    let startIndex = max(0, pinnedIndex - leadingRows)
    let endIndex = min(totalCount, pinnedIndex + leadingRows + visibleCount + 1)
    return startIndex..<max(startIndex + 1, endIndex)
  }

  private static func topSpacerHeight(
    startIndex: Int,
    metrics: SessionTimelineLayoutMetrics
  ) -> CGFloat {
    guard startIndex > 0, metrics.rows.indices.contains(startIndex) else {
      return 0
    }
    return max(0, metrics.rows[startIndex].top - HarnessMonitorTheme.itemSpacing)
  }

  private static func bottomSpacerHeight(
    endIndex: Int,
    metrics: SessionTimelineLayoutMetrics
  ) -> CGFloat {
    guard endIndex < metrics.rows.count, endIndex > 0 else {
      return 0
    }
    let lastRenderedRow = metrics.rows[endIndex - 1]
    return max(
      0,
      metrics.contentHeight - lastRenderedRow.bottom - HarnessMonitorTheme.itemSpacing
    )
  }
}

private struct SessionTimelineMeasuredRow: Equatable {
  let index: Int
  let id: String
  let top: CGFloat
  let height: CGFloat

  var bottom: CGFloat {
    top + height
  }
}

private struct SessionTimelineLayoutMetrics: Equatable {
  let rows: [SessionTimelineMeasuredRow]
  let contentHeight: CGFloat
}

struct SessionTimelineScrollMetrics: Equatable {
  static let coordinateSpaceName = "session-cockpit-timeline-scroll-space"

  var contentOffsetY: CGFloat
  var viewportHeight: CGFloat
  var contentHeight: CGFloat
  var visibleRect: CGRect

  static let zero = Self(
    contentOffsetY: 0,
    viewportHeight: 0,
    contentHeight: 0,
    visibleRect: .zero
  )

  init(
    contentOffsetY: CGFloat = 0,
    viewportHeight: CGFloat = 0,
    contentHeight: CGFloat = 0,
    visibleRect: CGRect = .zero
  ) {
    self.contentOffsetY = contentOffsetY
    self.viewportHeight = viewportHeight
    self.contentHeight = contentHeight
    self.visibleRect = visibleRect
  }

  init(geometry: ScrollGeometry) {
    self.init(
      contentOffsetY: geometry.contentOffset.y,
      viewportHeight: geometry.visibleRect.height,
      contentHeight: geometry.contentSize.height,
      visibleRect: geometry.visibleRect
    )
  }
}

struct SessionTimelineVisibilityStats: Equatable, Sendable {
  let visibleRowCount: Int
  let renderedRowCount: Int
  let loadedEventCount: Int
  let totalEventCount: Int

  static let empty = Self(
    visibleRowCount: 0,
    renderedRowCount: 0,
    loadedEventCount: 0,
    totalEventCount: 0
  )

  init(
    visibleRowCount: Int,
    renderedRowCount: Int,
    loadedEventCount: Int,
    totalEventCount: Int
  ) {
    self.visibleRowCount = max(0, visibleRowCount)
    self.renderedRowCount = max(0, renderedRowCount)
    self.loadedEventCount = max(0, loadedEventCount)
    self.totalEventCount = max(0, totalEventCount)
  }

  init(
    rowIDs: [String],
    rowFrames: [String: CGRect],
    scrollMetrics: SessionTimelineScrollMetrics,
    fallbackVisibleRowCount: Int,
    renderedRowCount: Int,
    loadedEventCount: Int,
    totalEventCount: Int
  ) {
    let visibleRowCount = Self.visibleRowCount(
      rowIDs: rowIDs,
      rowFrames: rowFrames,
      visibleRect: scrollMetrics.visibleRect,
      fallbackVisibleRowCount: fallbackVisibleRowCount
    )
    self.init(
      visibleRowCount: visibleRowCount,
      renderedRowCount: renderedRowCount,
      loadedEventCount: loadedEventCount,
      totalEventCount: totalEventCount
    )
  }

  var statusText: String {
    let renderedText = "Rendered rows \(renderedRowCount)"
    if totalEventCount == 0 {
      return "Visible rows \(visibleRowCount) | \(renderedText)"
    }
    let eventText = "Loaded events \(loadedEventCount)/\(totalEventCount)"
    return
      "Visible rows \(visibleRowCount) | \(renderedText) | \(eventText)"
  }

  static func visibleRowCount(
    rowIDs: [String],
    rowFrames: [String: CGRect],
    visibleRect: CGRect,
    fallbackVisibleRowCount: Int
  ) -> Int {
    guard !rowIDs.isEmpty else {
      return 0
    }
    let fallbackCount = min(rowIDs.count, max(0, fallbackVisibleRowCount))
    guard !visibleRect.isEmpty else {
      return fallbackCount
    }
    let measuredVisibleCount = rowIDs.reduce(into: 0) { count, rowID in
      guard let frame = rowFrames[rowID], frame.intersects(visibleRect) else {
        return
      }
      count += 1
    }
    if measuredVisibleCount == 0 {
      return fallbackCount
    }
    return measuredVisibleCount
  }
}

struct SessionTimelineRowFramePreferenceKey: PreferenceKey {
  static let defaultValue: [String: CGRect] = [:]

  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}
