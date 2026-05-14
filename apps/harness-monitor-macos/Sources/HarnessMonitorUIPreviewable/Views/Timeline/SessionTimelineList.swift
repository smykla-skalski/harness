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
    ) { _, newValue in
      guard newValue.contentMeasured else { return }
      guard newValue.distanceFromBottom <= SessionTimelineNearBottomState.threshold else { return }
      guard presentation.navigation.hasOlder else { return }
      onRequestLoadOlder?()
    }
    .task(id: SessionTimelineLoadOlderTaskKey(navigation: presentation.navigation)) {
      guard presentation.navigation.hasOlder else { return }
      try? await Task.sleep(for: .milliseconds(80))
      guard !Task.isCancelled, presentation.navigation.hasOlder else { return }
      onRequestLoadOlder?()
    }
  }
}

struct SessionTimelineNearBottomState: Equatable {
  static let threshold: CGFloat = 240

  let distanceFromBottom: CGFloat
  let contentMeasured: Bool

  init(geometry: ScrollGeometry) {
    let measured = geometry.contentSize.height > 0
    let distance = max(
      0,
      geometry.contentSize.height - geometry.contentOffset.y - geometry.visibleRect.height
    )
    self.init(distanceFromBottom: distance, contentMeasured: measured)
  }

  init(distanceFromBottom: CGFloat, contentMeasured: Bool) {
    self.distanceFromBottom = distanceFromBottom
    self.contentMeasured = contentMeasured
  }
}

struct SessionTimelineLoadOlderTaskKey: Hashable {
  let windowEnd: Int
  let totalCount: Int
  let hasOlder: Bool

  init(navigation: SessionTimelineWindowNavigation) {
    windowEnd = navigation.windowEnd
    totalCount = navigation.totalCount
    hasOlder = navigation.hasOlder
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
