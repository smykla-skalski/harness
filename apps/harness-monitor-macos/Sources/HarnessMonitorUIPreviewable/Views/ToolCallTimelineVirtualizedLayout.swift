import SwiftUI

struct ToolCallTimelineScrollMetrics: Equatable {
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

struct ToolCallTimelineVirtualizedLayout: Equatable {
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

  init(presentation: ToolCallTimelinePresentation, scrollMetrics _: ToolCallTimelineScrollMetrics) {
    let renderedSections = presentation.sections
    let renderedRowIDs = Set(renderedSections.flatMap(\.rows).map(\.id))

    self.init(
      sections: renderedSections,
      topSpacerHeight: 0,
      bottomSpacerHeight: 0,
      renderedRowIDs: renderedRowIDs
    )
  }
}
