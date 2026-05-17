import SwiftUI

struct ToolCallTimelineScrollMetrics: Equatable, Sendable {
  static let coordinateSpaceName = "tool-call-timeline-scroll-space"

  var contentOffsetY: CGFloat
  var viewportHeight: CGFloat
  var visibleRect: CGRect

  static let zero = Self(contentOffsetY: 0, viewportHeight: 0, visibleRect: .zero)

  init(contentOffsetY: CGFloat = 0, viewportHeight: CGFloat = 0, visibleRect: CGRect = .zero) {
    self.contentOffsetY = contentOffsetY
    self.viewportHeight = viewportHeight
    self.visibleRect = visibleRect
  }

  init(geometry: ScrollGeometry) {
    self.init(
      contentOffsetY: geometry.contentOffset.y,
      viewportHeight: geometry.visibleRect.height,
      visibleRect: geometry.visibleRect
    )
  }
}

struct ToolCallTimelineVirtualizedLayout: Equatable, Sendable {
  let sections: [ToolCallTimelineSection]
  let topSpacerHeight: CGFloat
  let bottomSpacerHeight: CGFloat
  let renderedRowIDs: Set<String>

  var renderedRowCount: Int {
    sections.reduce(0) { $0 + $1.rows.count }
  }

  static let empty = Self(
    sections: [],
    topSpacerHeight: 0,
    bottomSpacerHeight: 0,
    renderedRowIDs: []
  )

  init(
    sections: [ToolCallTimelineSection],
    topSpacerHeight: CGFloat,
    bottomSpacerHeight: CGFloat,
    renderedRowIDs: Set<String>
  ) {
    self.sections = sections
    self.topSpacerHeight = topSpacerHeight
    self.bottomSpacerHeight = bottomSpacerHeight
    self.renderedRowIDs = renderedRowIDs
  }

  init(presentation: ToolCallTimelinePresentation, scrollMetrics: ToolCallTimelineScrollMetrics) {
    let rows = presentation.rows
    guard !rows.isEmpty else {
      self = .empty
      return
    }

    let estimatedRowHeight: CGFloat = 54
    let fallbackViewportHeight: CGFloat = 260
    let viewportHeight = max(scrollMetrics.viewportHeight, fallbackViewportHeight)
    let overscanHeight = viewportHeight
    let lowerBound = max(0, scrollMetrics.contentOffsetY - overscanHeight)
    let upperBound = scrollMetrics.contentOffsetY + viewportHeight + overscanHeight
    let startIndex = max(0, Int((lowerBound / estimatedRowHeight).rounded(.down)))
    let endIndex = min(
      rows.count,
      max(startIndex + 1, Int((upperBound / estimatedRowHeight).rounded(.up)))
    )
    let renderedRows = Array(rows[startIndex..<endIndex])
    let renderedSections = ToolCallTimelinePresentation.sections(for: renderedRows)
    let renderedRowIDs = Set(renderedRows.map(\.id))

    self.init(
      sections: renderedSections,
      topSpacerHeight: CGFloat(startIndex) * estimatedRowHeight,
      bottomSpacerHeight: CGFloat(rows.count - endIndex) * estimatedRowHeight,
      renderedRowIDs: renderedRowIDs
    )
  }
}
