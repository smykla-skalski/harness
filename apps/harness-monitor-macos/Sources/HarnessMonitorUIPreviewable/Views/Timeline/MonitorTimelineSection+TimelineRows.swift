import SwiftUI

extension SessionTimelineView {
  func routeTimelineContent(
    for presentation: SessionTimelineSectionPresentation
  ) -> some View {
    timelineRows(
      for: presentation,
      horizontalContentInset: routeTimelineHorizontalContentInset
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder
  func timelineRows(
    for presentation: SessionTimelineSectionPresentation,
    horizontalContentInset: CGFloat = 0
  ) -> some View {
    if presentation.showsFilteredEmptyState {
      SessionTimelineFilteredEmptyState(filters: $filters)
    } else if presentation.rows.isEmpty {
      SessionTimelinePlaceholderScrollView(
        presentation: presentation,
        actionHandler: actionHandler,
        contentIdentity: contentIdentity,
        horizontalContentInset: horizontalContentInset
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else {
      timelineTable(
        for: presentation,
        horizontalContentInset: horizontalContentInset
      )
    }
  }

  private func timelineTable(
    for presentation: SessionTimelineSectionPresentation,
    horizontalContentInset: CGFloat
  ) -> some View {
    SessionTimelineTableView(
      columnWidth: measuredTimelineWidth,
      rows: presentation.rows,
      virtualization: presentation.tableVirtualization,
      contentIdentity: contentIdentity,
      horizontalContentInset: horizontalContentInset,
      scrollCommand: scrollCommand,
      actionHandler: actionHandler,
      onSignalTap: handleSignalTap,
      viewport: viewport,
      viewportChanged: handleViewportStatsChange,
      scrollBoundaryChanged: handleScrollBoundaryChange
    )
    .equatable()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      if abs(width - measuredTimelineWidth) >= 0.5 {
        measuredTimelineWidth = width
      }
    }
  }
}
