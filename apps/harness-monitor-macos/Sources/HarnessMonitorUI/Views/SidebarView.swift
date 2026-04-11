import HarnessMonitorKit
import SwiftUI

private final class SidebarSelectionTapBridge {
  var pendingTapSelectionID: String?
}

struct SidebarView: View {
  let store: HarnessMonitorStore
  let controls: HarnessMonitorStore.SessionControlsSlice
  let projection: HarnessMonitorStore.SessionProjectionSlice
  let searchResults: HarnessMonitorStore.SessionSearchResultsSlice
  let sidebarUI: HarnessMonitorStore.SidebarUISlice
  let sidebarVisible: Bool
  @Environment(\.harnessDateTimeConfiguration)
  var dateTimeConfiguration
  @Environment(\.fontScale)
  var fontScale

  @State private var collapsedCheckoutKeys: Set<String> = []
  @State private var sidebarWidth: CGFloat = 260
  @State private var sidebarVisibilityPhase = 1.0
  @State private var selectionTapBridge = SidebarSelectionTapBridge()
  @FocusState private var isSearchFocused: Bool
  private static let sidebarWidthMeasurementQuantum: CGFloat = 4
  private static let filterToolbarFadeHiddenWidth: CGFloat = 96
  private static let filterToolbarFadeVisibleWidth: CGFloat = 220

  init(
    store: HarnessMonitorStore,
    controls: HarnessMonitorStore.SessionControlsSlice,
    projection: HarnessMonitorStore.SessionProjectionSlice,
    searchResults: HarnessMonitorStore.SessionSearchResultsSlice,
    sidebarUI: HarnessMonitorStore.SidebarUISlice,
    sidebarVisible: Bool
  ) {
    self.store = store
    self.controls = controls
    self.projection = projection
    self.searchResults = searchResults
    self.sidebarUI = sidebarUI
    self.sidebarVisible = sidebarVisible
  }

  private var sidebarSelection: Binding<String?> {
    Binding(
      get: { renderedSidebarSelectionID },
      set: { newValue in
        if let pendingTapSelectionID = selectionTapBridge.pendingTapSelectionID {
          selectionTapBridge.pendingTapSelectionID = nil
          if pendingTapSelectionID == newValue {
            return
          }
        }
        if newValue == nil, sidebarUI.selectedSessionID != nil {
          return
        }
        guard sidebarUI.selectedSessionID != newValue else {
          return
        }
        store.selectSessionFromList(newValue)
      }
    )
  }

  private var renderedSidebarSelectionID: String? {
    guard let selectedSessionID = sidebarUI.selectedSessionID,
      searchResults.visibleSessionIDs.contains(selectedSessionID)
    else {
      return nil
    }
    return selectedSessionID
  }

  private var sidebarSearchText: Binding<String> {
    Binding(
      get: { controls.searchText },
      set: { newValue in
        guard controls.searchText != newValue else {
          return
        }
        store.searchText = newValue
      }
    )
  }

  private var hasActiveSidebarFilters: Bool {
    !controls.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || controls.sessionFilter != .all
      || controls.sessionFocusFilter != .all
      || controls.sessionSortOrder != .recentActivity
  }

  private var sidebarListRenderState: SidebarSessionListRenderState {
    SidebarSessionListRenderState(
      projectionGroups: projection.groupedSessions,
      searchPresentation: searchResults.presentationState,
      searchList: searchResults.listState,
      selectedSessionIDForAccessibilityMarkers: HarnessMonitorUITestEnvironment
        .accessibilityMarkersEnabled ? sidebarUI.selectedSessionID : nil,
      bookmarkedSessionIDs: sidebarUI.bookmarkedSessionIds,
      isPersistenceAvailable: sidebarUI.isPersistenceAvailable,
      dateTimeConfiguration: dateTimeConfiguration,
      fontScale: fontScale,
      collapsedCheckoutKeys: collapsedCheckoutKeys
    )
  }

  private var sidebarFilterStateValue: String {
    [
      "status=\(controls.sessionFilter.rawValue)",
      "focus=\(controls.sessionFocusFilter.rawValue)",
      "sort=\(controls.sessionSortOrder.rawValue)",
      "visible=\(searchResults.filteredSessionCount)",
      "total=\(searchResults.totalSessionCount)",
      "search=\(controls.searchText)",
    ].joined(separator: ", ")
  }

  // The sidebar search field already moves with the split view. Keep the
  // filter menu in that same toolbar lane and drive it from both the live
  // width and the split-view visibility state so it follows the motion but
  // still clears reliably once the sidebar finishes collapsing.
  private var filterToolbarVisibilityProgress: Double {
    let hiddenWidth = Self.filterToolbarFadeHiddenWidth
    let visibleWidth = Self.filterToolbarFadeVisibleWidth
    let widthProgress = Double(
      max(0, min(1, (sidebarWidth - hiddenWidth) / (visibleWidth - hiddenWidth))))
    return min(widthProgress, sidebarVisibilityPhase)
  }

  var body: some View {
    List(selection: sidebarSelection) {
      SidebarSessionListContent(
        renderState: sidebarListRenderState,
        selectSession: { sessionID in
          selectionTapBridge.pendingTapSelectionID = sessionID
          store.selectSessionFromList(sessionID)
        },
        toggleBookmark: { sessionID, projectID in
          store.toggleBookmark(sessionId: sessionID, projectId: projectID)
        },
        setCheckoutCollapsed: setCheckoutCollapsed
      )
    }
    .listStyle(.sidebar)
    .scrollEdgeEffectStyle(.soft, for: .top)
    .searchable(
      text: sidebarSearchText,
      placement: .sidebar,
      prompt: "Search sessions, projects, leaders"
    )
    .searchFocused($isSearchFocused)
    .safeAreaInset(edge: .top, spacing: 0) {
      sidebarHeader
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      SidebarFooterMetricsBridge(sidebarUI: sidebarUI)
    }
    .toolbar {
      if filterToolbarVisibilityProgress > 0.02 {
        ToolbarItem(placement: .primaryAction) {
          SidebarToolbarFilterMenu(
            store: store,
            sessionFilter: controls.sessionFilter,
            sessionFocusFilter: controls.sessionFocusFilter,
            sessionSortOrder: controls.sessionSortOrder,
            hasActiveFilters: hasActiveSidebarFilters
          )
          .opacity(filterToolbarVisibilityProgress)
          .scaleEffect(
            x: 0.94 + (0.06 * filterToolbarVisibilityProgress),
            y: 0.94 + (0.06 * filterToolbarVisibilityProgress),
            anchor: .trailing
          )
          .allowsHitTesting(filterToolbarVisibilityProgress > 0.85)
          .accessibilityHidden(filterToolbarVisibilityProgress < 0.15)
          .animation(.easeInOut(duration: 0.12), value: filterToolbarVisibilityProgress)
        }
      }
    }
    .onSubmit(of: .search) {
      store.flushPendingSearchRebuild()
      if sidebarUI.isPersistenceAvailable {
        _ = store.recordSearch(controls.searchText)
      }
    }
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      updateSidebarWidth(width)
    }
    .onChange(of: sidebarVisible, initial: true) { _, isVisible in
      let nextPhase = isVisible ? 1.0 : 0.0
      guard sidebarVisibilityPhase != nextPhase else {
        return
      }
      withAnimation(.easeInOut(duration: 0.18)) {
        sidebarVisibilityPhase = nextPhase
      }
    }
    .onChange(of: sidebarUI.searchFocusRequest) { _, _ in
      isSearchFocused = true
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .accessibilityFrameMarker(HarnessMonitorAccessibility.sidebarShellFrame)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarRoot)
    .overlay {
      if HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled {
        AccessibilityTextMarker(
          identifier: HarnessMonitorAccessibility.sidebarFilterState,
          text: sidebarFilterStateValue
        )
      }
    }
  }

  @ViewBuilder private var sidebarHeader: some View {
    SidebarRecentSearchesHeader(
      isPersistenceAvailable: sidebarUI.isPersistenceAvailable,
      applyQuery: applyRecentSearch,
      clearHistory: { _ = store.clearSearchHistory() }
    )
  }

  func updateSidebarWidth(_ width: CGFloat) {
    let quantizedWidth =
      max(
        (width / Self.sidebarWidthMeasurementQuantum).rounded()
          * Self.sidebarWidthMeasurementQuantum,
        0
      )
    guard abs(quantizedWidth - sidebarWidth) >= 1 else {
      return
    }
    sidebarWidth = quantizedWidth
  }

  func setCheckoutCollapsed(
    checkoutKey: String,
    isCollapsed: Bool
  ) {
    if isCollapsed {
      collapsedCheckoutKeys.insert(checkoutKey)
    } else {
      collapsedCheckoutKeys.remove(checkoutKey)
    }
  }

  private func applyRecentSearch(_ query: String) {
    store.searchText = query
    store.flushPendingSearchRebuild()
    if sidebarUI.isPersistenceAvailable {
      _ = store.recordSearch(query)
    }
  }
}

private struct SidebarFooterMetricsBridge: View {
  let sidebarUI: HarnessMonitorStore.SidebarUISlice

  var body: some View {
    SidebarFooterAccessory(metrics: sidebarUI.connectionMetrics)
  }
}
