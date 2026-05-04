import CoreGraphics

// NSTableView owns the hot scroll path here: row reuse, visible ranges, and content
// offset preservation stay in AppKit instead of feeding per-row geometry back into SwiftUI.
enum SessionTimelineTableMetrics {
  static let estimatedBaseRowHeight: CGFloat = 92
  private static let dayDividerHeight: CGFloat = 30
  private static let detailHeight: CGFloat = 20
  private static let singleLineActionHeight: CGFloat = 42
  private static let wrappedActionHeight: CGFloat = 78

  static func prefersCompactLayout(for row: SessionTimelineRow) -> Bool {
    row.node.sourceLabel.hasPrefix("signal_")
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

  static func estimatedHeight(for row: SessionTimelineRow) -> CGFloat {
    var height = estimatedBaseRowHeight
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
