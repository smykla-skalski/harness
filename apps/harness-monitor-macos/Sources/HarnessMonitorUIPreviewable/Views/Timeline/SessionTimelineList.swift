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
        SessionTimelineLoadOlderMarker(
          hasOlder: presentation.navigation.hasOlder,
          onLoadOlder: onRequestLoadOlder
        )
        .id(SessionTimelineLoadOlderMarker.identity(for: presentation.navigation))
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
  }
}

struct SessionTimelineLoadOlderMarker: View {
  let hasOlder: Bool
  let onLoadOlder: (() -> Void)?

  var body: some View {
    Color.clear
      .frame(maxWidth: .infinity)
      .frame(height: 1)
      .accessibilityHidden(true)
      .onAppear {
        guard hasOlder else { return }
        onLoadOlder?()
      }
  }

  static func identity(for navigation: SessionTimelineWindowNavigation) -> String {
    "load-older-marker:\(navigation.windowEnd):\(navigation.totalCount):\(navigation.hasOlder ? 1 : 0)"
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
