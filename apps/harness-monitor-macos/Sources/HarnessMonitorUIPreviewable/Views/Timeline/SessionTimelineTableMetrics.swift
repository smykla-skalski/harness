import CoreGraphics

struct SessionTimelineConnectorVisibility {
  let showsConnectorAbove: Bool
  let showsConnectorBelow: Bool

  static let all = Self(showsConnectorAbove: true, showsConnectorBelow: true)
}

// NSTableView owns the hot scroll path here: row reuse, visible ranges, and content
// offset preservation stay in AppKit instead of feeding per-row geometry back into SwiftUI.
enum SessionTimelineTableMetrics {
  static let estimatedBaseRowHeight: CGFloat = 92
  static let pinnedLatestDriftTolerance: CGFloat = 1
  private static let minimumSimpleWideCardHeight: CGFloat = 40
  private static let minimumDetailedWideCardHeight: CGFloat = 60
  private static let minimumCompactCardHeight: CGFloat = 96
  private static let dayDividerHeight: CGFloat = 30
  private static let detailHeight: CGFloat = 20
  private static let singleLineActionHeight: CGFloat = 42
  private static let wrappedActionHeight: CGFloat = 78

  static func prefersCompactLayout(for row: SessionTimelineRow) -> Bool {
    row.node.prefersCompactLayout ?? false
  }

  static func resolvedColumnWidth(
    proposedWidth: CGFloat,
    visibleContentWidth: CGFloat
  ) -> CGFloat {
    let safeProposedWidth = max(proposedWidth, 0)
    guard visibleContentWidth > 1 else {
      return safeProposedWidth
    }
    guard safeProposedWidth > 1 else {
      return visibleContentWidth
    }
    return min(safeProposedWidth, visibleContentWidth)
  }

  static func minimumCardHeight(
    for row: SessionTimelineRow,
    fontScale: CGFloat = 1.0
  ) -> CGFloat {
    let scale = max(1, fontScale)
    if prefersCompactLayout(for: row) {
      return minimumCompactCardHeight * scale
    }
    if usesSimpleWideLayout(for: row) {
      return minimumSimpleWideCardHeight * scale
    }
    return minimumDetailedWideCardHeight * scale
  }

  static func rowBottomPadding(for _: SessionTimelineRow) -> CGFloat {
    HarnessMonitorTheme.itemSpacing
  }

  static func connectorVisibility(
    rowIndex: Int,
    rowCount: Int
  ) -> SessionTimelineConnectorVisibility {
    guard rowCount > 0, rowIndex >= 0, rowIndex < rowCount else {
      return .init(showsConnectorAbove: false, showsConnectorBelow: false)
    }
    return .init(
      showsConnectorAbove: rowIndex > 0,
      showsConnectorBelow: rowIndex + 1 < rowCount
    )
  }

  static func shouldStickToLatestOnRowsChange(
    visibleMinY: CGFloat,
    firstVisibleRowIndex: Int?
  ) -> Bool {
    guard let firstVisibleRowIndex else {
      return false
    }
    return firstVisibleRowIndex == 0 && visibleMinY <= pinnedLatestDriftTolerance
  }

  static func usesSimpleWideLayout(for row: SessionTimelineRow) -> Bool {
    !prefersCompactLayout(for: row)
      && row.node.detail == nil
      && row.node.actions.isEmpty
  }

  static func estimatedHeight(
    for row: SessionTimelineRow,
    fontScale: CGFloat = 1.0
  ) -> CGFloat {
    var height = max(estimatedBaseRowHeight, minimumCardHeight(for: row, fontScale: fontScale))
    if row.dayDividerLabel != nil {
      height += dayDividerHeight
    }
    if row.node.detail != nil {
      height += detailHeight
    }
    if !row.node.actions.isEmpty {
      height += actionHeight(for: row.node.actions.count)
    }
    return height
  }

  static func restoredScrollY(
    rowMinY: CGFloat,
    anchorOffsetY: CGFloat,
    contentHeight: CGFloat,
    viewportHeight: CGFloat
  ) -> CGFloat {
    clampedScrollY(
      rowMinY + anchorOffsetY,
      contentHeight: contentHeight,
      viewportHeight: viewportHeight
    )
  }

  static func clampedScrollY(
    _ y: CGFloat,
    contentHeight: CGFloat,
    viewportHeight: CGFloat
  ) -> CGFloat {
    let maxY = max(0, contentHeight - viewportHeight)
    return max(0, min(y, maxY))
  }

  private static func actionHeight(for actionCount: Int) -> CGFloat {
    actionCount > 2 ? wrappedActionHeight : singleLineActionHeight
  }
}
