import HarnessMonitorKit
import SwiftUI

struct SessionTimelineList: View {
  let presentation: SessionTimelineSectionPresentation
  let actionHandler: any DecisionActionHandler
  let onSignalTap: ((String) -> Void)?
  let fontScale: CGFloat
  let horizontalContentInset: CGFloat
  let filters: Binding<SessionTimelineFilterState>
  let onRequestLoadOlder: (() -> Void)?

  init(
    presentation: SessionTimelineSectionPresentation,
    actionHandler: any DecisionActionHandler,
    onSignalTap: ((String) -> Void)?,
    fontScale: CGFloat,
    horizontalContentInset: CGFloat,
    filters: Binding<SessionTimelineFilterState>,
    onRequestLoadOlder: (() -> Void)? = nil
  ) {
    self.presentation = presentation
    self.actionHandler = actionHandler
    self.onSignalTap = onSignalTap
    self.fontScale = fontScale
    self.horizontalContentInset = horizontalContentInset
    self.filters = filters
    self.onRequestLoadOlder = onRequestLoadOlder
  }

  var body: some View {
    Group {
      if presentation.showsFilteredEmptyState {
        SessionTimelineFilteredEmptyState(filters: filters)
      } else if presentation.rows.isEmpty && presentation.navigation.isLoading {
        HarnessMonitorSpinner(size: 14)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        timelineScroll
      }
    }
  }

  private var timelineScroll: some View {
    ScrollView(.vertical) {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(presentation.rows) { row in
          SessionTimelineRowView(
            row: row,
            actionHandler: actionHandler,
            onSignalTap: onSignalTap,
            fontScale: fontScale
          )
          .equatable()
          .id(row.id)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .coordinateSpace(.named(SessionTimelineRailCoordinateSpace.name))
      .background(alignment: .topLeading) {
        if !presentation.rows.isEmpty {
          SessionTimelineRailBackground()
        }
      }
      .padding(.horizontal, horizontalContentInset)
    }
    .scrollIndicators(.visible)
    .scrollBounceBehavior(.basedOnSize, axes: .vertical)
    .onScrollGeometryChange(
      for: SessionTimelineNearBottomState.self,
      of: SessionTimelineNearBottomState.init(geometry:)
    ) { oldValue, newValue in
      let nav = presentation.navigation
      HarnessMonitorLogger.timelinePaging.debug(
        """
        view.scrollGeometry distance=\(newValue.distanceFromBottom, privacy: .public) \
        measured=\(newValue.contentMeasured, privacy: .public) \
        offset=\(newValue.contentOffsetY, privacy: .public) \
        offsetPrev=\(oldValue.contentOffsetY, privacy: .public) \
        hasOlder=\(nav.hasOlder, privacy: .public) \
        windowEnd=\(nav.windowEnd, privacy: .public) totalCount=\(nav.totalCount, privacy: .public)
        """
      )
      guard newValue.contentMeasured else { return }
      // Only react to user-driven scrolls (offset changed). Skip content-size-only
      // changes, otherwise an older-load that grows the timeline would itself
      // chain-trigger another load while the user sits still.
      guard newValue.contentOffsetY != oldValue.contentOffsetY else { return }
      guard newValue.distanceFromBottom <= SessionTimelineNearBottomState.threshold else { return }
      guard nav.hasOlder else { return }
      HarnessMonitorLogger.timelinePaging.info("view.scrollGeometry FIRE")
      onRequestLoadOlder?()
    }
  }
}

struct SessionTimelineNearBottomState: Equatable {
  static let threshold: CGFloat = 240

  let distanceFromBottom: CGFloat
  let contentMeasured: Bool
  let contentOffsetY: CGFloat

  init(geometry: ScrollGeometry) {
    let measured = geometry.contentSize.height > 0
    let distance = max(
      0,
      geometry.contentSize.height - geometry.contentOffset.y - geometry.visibleRect.height
    )
    self.init(
      distanceFromBottom: distance,
      contentMeasured: measured,
      contentOffsetY: geometry.contentOffset.y
    )
  }

  init(distanceFromBottom: CGFloat, contentMeasured: Bool, contentOffsetY: CGFloat = 0) {
    self.distanceFromBottom = distanceFromBottom
    self.contentMeasured = contentMeasured
    self.contentOffsetY = contentOffsetY
  }
}

struct SessionTimelineFilteredEmptyState: View {
  @Binding var filters: SessionTimelineFilterState

  var body: some View {
    VStack(spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "line.3.horizontal.decrease.circle")
        .font(.title2)
        .foregroundStyle(.secondary)
      Text("No timeline items match these filters")
        .scaledFont(.body.weight(.semibold))
      Button("Clear filters") {
        filters.clear()
      }
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(HarnessMonitorTheme.spacingLG)
  }
}
