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
      for: SessionTimelineLoadOlderTrigger.self,
      of: SessionTimelineLoadOlderTrigger.init(geometry:)
    ) { oldValue, newValue in
      let firstRender = !oldValue.contentRendered && newValue.contentRendered
      let risingNearBottom = !oldValue.isNearBottom && newValue.isNearBottom
      guard firstRender || risingNearBottom else { return }
      guard newValue.isNearBottom, presentation.navigation.hasOlder else { return }
      onRequestLoadOlder?()
    }
  }
}

struct SessionTimelineLoadOlderTrigger: Equatable {
  static let nearBottomThreshold: CGFloat = 320

  let isNearBottom: Bool
  let contentRendered: Bool

  init(isNearBottom: Bool, contentRendered: Bool = true) {
    self.isNearBottom = isNearBottom
    self.contentRendered = contentRendered
  }

  init(geometry: ScrollGeometry) {
    self.init(
      contentHeight: geometry.contentSize.height,
      contentOffsetY: geometry.contentOffset.y,
      viewportHeight: geometry.visibleRect.height
    )
  }

  init(contentHeight: CGFloat, contentOffsetY: CGFloat, viewportHeight: CGFloat) {
    let distanceFromBottom = max(0, contentHeight - contentOffsetY - viewportHeight)
    self.init(
      isNearBottom: distanceFromBottom <= Self.nearBottomThreshold,
      contentRendered: contentHeight > 0
    )
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
