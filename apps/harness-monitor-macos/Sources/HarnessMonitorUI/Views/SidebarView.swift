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
  let onSidebarWidthChange: (CGFloat) -> Void
  @Environment(\.harnessDateTimeConfiguration)
  var dateTimeConfiguration
  @Environment(\.fontScale)
  var fontScale

  @State private var collapsedCheckoutKeys: Set<String> = []
  @State private var sidebarWidth: CGFloat = 260
  @State private var sidebarVisibilityPhase = 1.0
  @State private var selectionTapBridge = SidebarSelectionTapBridge()
  @State private var searchDraftText: String
  @FocusState private var isSearchFocused: Bool
  private static let sidebarWidthMeasurementQuantum: CGFloat = 4
  private static let filterToolbarFadeHiddenWidth: CGFloat = 96
  private static let filterToolbarFadeVisibleWidth: CGFloat = 220
  private static let searchCommitDebounceNanoseconds: UInt64 = 250_000_000

  init(
    store: HarnessMonitorStore,
    controls: HarnessMonitorStore.SessionControlsSlice,
    projection: HarnessMonitorStore.SessionProjectionSlice,
    searchResults: HarnessMonitorStore.SessionSearchResultsSlice,
    sidebarUI: HarnessMonitorStore.SidebarUISlice,
    sidebarVisible: Bool,
    onSidebarWidthChange: @escaping (CGFloat) -> Void = { _ in }
  ) {
    self.store = store
    self.controls = controls
    self.projection = projection
    self.searchResults = searchResults
    self.sidebarUI = sidebarUI
    self.sidebarVisible = sidebarVisible
    self.onSidebarWidthChange = onSidebarWidthChange
    _searchDraftText = State(initialValue: controls.searchText)
  }

  private var sidebarSearchText: Binding<String> {
    Binding(
      get: { searchDraftText },
      set: { searchDraftText = $0 }
    )
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
    SidebarSessionListColumn(
      store: store,
      projection: projection,
      searchResults: searchResults,
      sidebarUI: sidebarUI,
      dateTimeConfiguration: dateTimeConfiguration,
      fontScale: fontScale,
      collapsedCheckoutKeys: collapsedCheckoutKeys,
      selectionTapBridge: selectionTapBridge,
      setCheckoutCollapsed: setCheckoutCollapsed
    )
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
      SidebarToolbarFilterToolbarItem(
        store: store,
        controls: controls,
        searchResults: searchResults,
        visibilityProgress: filterToolbarVisibilityProgress
      )
    }
    .task(id: searchDraftText) {
      guard searchDraftText != controls.searchText else {
        return
      }
      try? await Task.sleep(nanoseconds: Self.searchCommitDebounceNanoseconds)
      guard !Task.isCancelled, searchDraftText != controls.searchText else {
        return
      }
      commitSearchDraft(flushProjection: true)
    }
    .onSubmit(of: .search) {
      commitSearchDraft(flushProjection: true)
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
    .onChange(of: controls.searchText, initial: true) { _, newValue in
      guard searchDraftText != newValue else {
        return
      }
      searchDraftText = newValue
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .accessibilityFrameMarker(HarnessMonitorAccessibility.sidebarShellFrame)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarRoot)
    .overlay {
      SidebarFilterStateMarker(
        controls: controls,
        searchResults: searchResults
      )
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
    onSidebarWidthChange(quantizedWidth)
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
    searchDraftText = query
    commitSearchDraft(flushProjection: true)
    if sidebarUI.isPersistenceAvailable {
      _ = store.recordSearch(query)
    }
  }

  private func commitSearchDraft(flushProjection: Bool) {
    guard controls.searchText != searchDraftText else {
      return
    }
    store.searchText = searchDraftText
    if flushProjection {
      store.flushPendingSearchRebuild()
    }
  }
}

private struct SidebarToolbarFilterToolbarItem: ToolbarContent {
  let store: HarnessMonitorStore
  let controls: HarnessMonitorStore.SessionControlsSlice
  let searchResults: HarnessMonitorStore.SessionSearchResultsSlice
  let visibilityProgress: Double

  private var hasActiveFilters: Bool {
    !controls.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || controls.sessionFilter != .all
      || controls.sessionFocusFilter != .all
      || controls.sessionSortOrder != .recentActivity
  }

  var body: some ToolbarContent {
    if visibilityProgress > 0.02 {
      ToolbarItem(placement: .primaryAction) {
        SidebarToolbarFilterMenu(
          store: store,
          sessionFilter: controls.sessionFilter,
          sessionFocusFilter: controls.sessionFocusFilter,
          sessionSortOrder: controls.sessionSortOrder,
          hasActiveFilters: hasActiveFilters
        )
        .opacity(visibilityProgress)
        .scaleEffect(
          x: 0.94 + (0.06 * visibilityProgress),
          y: 0.94 + (0.06 * visibilityProgress),
          anchor: .trailing
        )
        .allowsHitTesting(visibilityProgress > 0.85)
        .accessibilityHidden(visibilityProgress < 0.15)
        .animation(.easeInOut(duration: 0.12), value: visibilityProgress)
      }
    }
  }
}

private struct SidebarFilterStateMarker: View {
  let controls: HarnessMonitorStore.SessionControlsSlice
  let searchResults: HarnessMonitorStore.SessionSearchResultsSlice

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

  var body: some View {
    if HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled {
      AccessibilityTextMarker(
        identifier: HarnessMonitorAccessibility.sidebarFilterState,
        text: sidebarFilterStateValue
      )
    }
  }
}

private struct SidebarSessionListColumn: View {
  let store: HarnessMonitorStore
  let projection: HarnessMonitorStore.SessionProjectionSlice
  let searchResults: HarnessMonitorStore.SessionSearchResultsSlice
  let sidebarUI: HarnessMonitorStore.SidebarUISlice
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration
  let fontScale: CGFloat
  let collapsedCheckoutKeys: Set<String>
  let selectionTapBridge: SidebarSelectionTapBridge
  let setCheckoutCollapsed: (String, Bool) -> Void

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

  private var renderState: SidebarSessionListRenderState {
    SidebarSessionListRenderState(
      projectionGroups: projection.groupedSessions,
      searchPresentation: searchResults.presentationState,
      searchVisibleSessions: searchResults.visibleSessions,
      selectedSessionIDForAccessibilityMarkers: HarnessMonitorUITestEnvironment
        .selectionMarkersEnabled ? sidebarUI.selectedSessionID : nil,
      bookmarkedSessionIDs: sidebarUI.bookmarkedSessionIds,
      isPersistenceAvailable: sidebarUI.isPersistenceAvailable,
      dateTimeConfiguration: dateTimeConfiguration,
      fontScale: fontScale,
      collapsedCheckoutKeys: collapsedCheckoutKeys
    )
  }

  var body: some View {
    List(selection: sidebarSelection) {
      SidebarSessionListContent(
        renderState: renderState,
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
  }
}

private struct SidebarFooterMetricsBridge: View {
  let sidebarUI: HarnessMonitorStore.SidebarUISlice

  var body: some View {
    SidebarFooterAccessory(metrics: sidebarUI.connectionMetrics)
  }
}
