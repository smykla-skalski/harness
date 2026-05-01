import SwiftUI

struct ToolCallTimelineScrollMetrics: Equatable {
  var contentOffsetY: CGFloat
  var viewportHeight: CGFloat

  static let zero = Self(contentOffsetY: 0, viewportHeight: 0)

  init(contentOffsetY: CGFloat = 0, viewportHeight: CGFloat = 0) {
    self.contentOffsetY = contentOffsetY
    self.viewportHeight = viewportHeight
  }

  init(geometry: ScrollGeometry) {
    self.init(
      contentOffsetY: geometry.contentOffset.y,
      viewportHeight: geometry.visibleRect.height
    )
  }
}

struct ToolCallTimelineVirtualizedLayout: Equatable {
  private static let estimatedRowHeight: CGFloat = 56
  private static let estimatedHeaderHeight: CGFloat = 34
  private static let sectionSpacing: CGFloat = HarnessMonitorTheme.spacingSM
  private static let rowSpacing: CGFloat = HarnessMonitorTheme.spacingXS
  private static let overscanHeight: CGFloat = 320

  let sections: [ToolCallTimelineSection]
  let topSpacerHeight: CGFloat
  let bottomSpacerHeight: CGFloat
  let renderedRowIDs: Set<String>
  let viewportVisibleRowIDs: Set<String>

  var renderedRowCount: Int {
    sections.reduce(0) { $0 + $1.rows.count }
  }

  static let empty = Self(
    sections: [],
    topSpacerHeight: 0,
    bottomSpacerHeight: 0,
    renderedRowIDs: [],
    viewportVisibleRowIDs: []
  )

  init(
    sections: [ToolCallTimelineSection],
    topSpacerHeight: CGFloat,
    bottomSpacerHeight: CGFloat,
    renderedRowIDs: Set<String>,
    viewportVisibleRowIDs: Set<String>
  ) {
    self.sections = sections
    self.topSpacerHeight = topSpacerHeight
    self.bottomSpacerHeight = bottomSpacerHeight
    self.renderedRowIDs = renderedRowIDs
    self.viewportVisibleRowIDs = viewportVisibleRowIDs
  }

  init(presentation: ToolCallTimelinePresentation, scrollMetrics: ToolCallTimelineScrollMetrics) {
    guard !presentation.sections.isEmpty else {
      self = .empty
      return
    }

    let spans = Self.sectionSpans(for: presentation.sections)
    let viewportHeight = max(1, scrollMetrics.viewportHeight)
    let viewportTop = max(0, scrollMetrics.contentOffsetY)
    let viewportBottom = max(viewportTop + 1, scrollMetrics.contentOffsetY + viewportHeight)
    let windowTop = max(0, viewportTop - Self.overscanHeight)
    let windowBottom = max(
      windowTop + 1,
      viewportBottom + Self.overscanHeight
    )

    let renderedSpans = spans.filter { span in
      span.endY >= windowTop && span.startY <= windowBottom
    }
    let viewportVisibleSpans = spans.filter { span in
      span.endY >= viewportTop && span.startY <= viewportBottom
    }

    guard let first = renderedSpans.first, let last = renderedSpans.last else {
      // Keep at least one section rendered so stale geometry never blanks the timeline.
      let fallbackSection = presentation.sections.first
      let fallbackRenderedIDs = Set(fallbackSection?.rows.map(\.id) ?? [])
      self.init(
        sections: fallbackSection.map { [$0] } ?? [],
        topSpacerHeight: 0,
        bottomSpacerHeight: 0,
        renderedRowIDs: fallbackRenderedIDs,
        viewportVisibleRowIDs: []
      )
      return
    }

    let renderedSections = renderedSpans.map(\.section)
    let totalHeight = spans.last?.endY ?? 0
    let topSpacerHeight = max(0, first.startY)
    let bottomSpacerHeight = max(0, totalHeight - last.endY)
    let renderedRowIDs = Set(renderedSections.flatMap(\.rows).map(\.id))
    let viewportVisibleRowIDs = Set(viewportVisibleSpans.flatMap(\.section.rows).map(\.id))

    self.init(
      sections: renderedSections,
      topSpacerHeight: topSpacerHeight,
      bottomSpacerHeight: bottomSpacerHeight,
      renderedRowIDs: renderedRowIDs,
      viewportVisibleRowIDs: viewportVisibleRowIDs
    )
  }

  private static func sectionSpans(
    for sections: [ToolCallTimelineSection]
  ) -> [ToolCallTimelineSectionSpan] {
    var spans: [ToolCallTimelineSectionSpan] = []
    spans.reserveCapacity(sections.count)
    var cursorY: CGFloat = 0

    for (index, section) in sections.enumerated() {
      if index > 0 {
        cursorY += sectionSpacing
      }
      let startY = cursorY
      cursorY += estimatedSectionHeight(section)
      spans.append(
        ToolCallTimelineSectionSpan(
          section: section,
          startY: startY,
          endY: cursorY
        )
      )
    }

    return spans
  }

  private static func estimatedSectionHeight(_ section: ToolCallTimelineSection) -> CGFloat {
    let rowCount = section.rows.count
    guard rowCount > 0 else {
      return 0
    }

    var height = CGFloat(rowCount) * estimatedRowHeight
    if rowCount > 1 {
      height += CGFloat(rowCount - 1) * rowSpacing
    }
    if section.showsHeader {
      height += estimatedHeaderHeight + rowSpacing
    }
    return height
  }
}

private struct ToolCallTimelineSectionSpan {
  let section: ToolCallTimelineSection
  let startY: CGFloat
  let endY: CGFloat
}
