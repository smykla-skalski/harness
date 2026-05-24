import HarnessMonitorKit
import SwiftUI

struct SessionTimelineList: View {
  let presentation: SessionTimelineSectionPresentation
  let actionHandler: any DecisionActionHandler
  let onSignalTap: ((String) -> Void)?
  let fontScale: CGFloat
  let horizontalContentInset: CGFloat
  let filters: Binding<SessionTimelineFilterState>
  let focusedEntryID: String?
  let onRequestLoadOlder: (() -> Void)?

  init(
    presentation: SessionTimelineSectionPresentation,
    actionHandler: any DecisionActionHandler,
    onSignalTap: ((String) -> Void)?,
    fontScale: CGFloat,
    horizontalContentInset: CGFloat,
    filters: Binding<SessionTimelineFilterState>,
    focusedEntryID: String? = nil,
    onRequestLoadOlder: (() -> Void)? = nil
  ) {
    self.presentation = presentation
    self.actionHandler = actionHandler
    self.onSignalTap = onSignalTap
    self.fontScale = fontScale
    self.horizontalContentInset = horizontalContentInset
    self.filters = filters
    self.focusedEntryID = focusedEntryID
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
    let key = focusKey
    return ScrollViewReader { proxy in
      ScrollView(.vertical) {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(presentation.rows) { row in
            SessionTimelineRowView(
              row: row,
              actionHandler: actionHandler,
              onSignalTap: onSignalTap,
              fontScale: fontScale,
              isFocused: key.rowID == row.id
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
      .task(id: key) {
        scrollFocusedEntryIfNeeded(proxy: proxy, key: key)
      }
      .onScrollGeometryChange(
        for: SessionTimelineNearBottomState.self,
        of: SessionTimelineNearBottomState.init(geometry:)
      ) { oldValue, newValue in
        guard newValue.contentMeasured else { return }
        // Only react to user-driven scrolls (offset changed). Content-size-only
        // changes (from an older-load growing the timeline) would otherwise
        // chain-trigger another load while the user sits still.
        guard newValue.contentOffsetY != oldValue.contentOffsetY else { return }
        guard
          newValue.distanceFromBottom <= SessionTimelineNearBottomState.threshold
        else { return }
        guard presentation.navigation.hasOlder else { return }
        onRequestLoadOlder?()
      }
    }
  }

  private var focusKey: SessionTimelineFocusRequestKey {
    SessionTimelineFocusRequestKey(entryID: focusedEntryID, rows: presentation.rows)
  }

  @MainActor
  private func scrollFocusedEntryIfNeeded(
    proxy: ScrollViewProxy,
    key: SessionTimelineFocusRequestKey
  ) {
    guard key.containsTarget, let rowID = key.rowID else { return }
    withAnimation(.easeInOut(duration: 0.16)) {
      proxy.scrollTo(rowID, anchor: .center)
    }
  }
}

private struct SessionTimelineFocusRequestKey: Equatable {
  let entryID: String?
  let rowID: String?
  let rowCount: Int
  let firstRowID: String?
  let lastRowID: String?
  let containsTarget: Bool

  init(entryID: String?, rows: [SessionTimelineRow]) {
    self.entryID = entryID
    rowID = entryID.map { "entry:\($0)" }
    rowCount = rows.count
    firstRowID = rows.first?.id
    lastRowID = rows.last?.id
    containsTarget = rowID.map { id in rows.contains { $0.id == id } } ?? false
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
