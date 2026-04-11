import HarnessMonitorKit
import SwiftUI

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

  @SceneStorage("sidebar.collapsed-project-ids")
  var collapsedProjectIDsStorage = ""
  @SceneStorage("sidebar.collapsed-checkout-keys")
  var collapsedCheckoutKeysStorage = ""
  @State private var collapsedProjectIDsState: Set<String> = []
  @State private var collapsedCheckoutKeysState: Set<String> = []
  @State private var hasHydratedCollapsedState = false
  @State private var sidebarWidth: CGFloat = 260
  @State private var sidebarVisibilityPhase = 1.0
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

  var collapsedProjectIDs: Set<String> {
    if hasHydratedCollapsedState {
      collapsedProjectIDsState
    } else {
      decodedStorageSet(from: collapsedProjectIDsStorage)
    }
  }

  var collapsedCheckoutKeys: Set<String> {
    if hasHydratedCollapsedState {
      collapsedCheckoutKeysState
    } else {
      decodedStorageSet(from: collapsedCheckoutKeysStorage)
    }
  }

  private var sidebarSelection: Binding<String?> {
    Binding(
      get: { renderedSidebarSelectionID },
      set: { newValue in
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
      selectedSessionID: sidebarUI.selectedSessionID,
      bookmarkedSessionIDs: sidebarUI.bookmarkedSessionIds,
      isPersistenceAvailable: sidebarUI.isPersistenceAvailable,
      dateTimeConfiguration: dateTimeConfiguration,
      fontScale: fontScale,
      collapsedProjectIDs: collapsedProjectIDs,
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
    SidebarSessionListContent(
      renderState: sidebarListRenderState,
      selection: sidebarSelection,
      selectSession: { store.selectSessionFromList($0) },
      toggleBookmark: { sessionID, projectID in
        store.toggleBookmark(sessionId: sessionID, projectId: projectID)
      },
      setProjectCollapsed: setProjectCollapsed,
      setCheckoutCollapsed: setCheckoutCollapsed
    )
    .equatable()
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
    .onAppear(perform: hydrateCollapsedStateIfNeeded)
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
    .onChange(of: collapsedProjectIDsStorage) { _, newValue in
      syncCollapsedProjects(from: newValue)
    }
    .onChange(of: collapsedCheckoutKeysStorage) { _, newValue in
      syncCollapsedCheckouts(from: newValue)
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

  func decodedStorageSet(from rawValue: String) -> Set<String> {
    Set(
      rawValue
        .split(separator: "\n")
        .map(String.init)
        .filter { !$0.isEmpty }
    )
  }

  func encodedStorageSet(
    _ values: Set<String>
  ) -> String {
    values.sorted().joined(separator: "\n")
  }

  func hydrateCollapsedStateIfNeeded() {
    guard !hasHydratedCollapsedState else {
      return
    }

    collapsedProjectIDsState = decodedStorageSet(from: collapsedProjectIDsStorage)
    collapsedCheckoutKeysState = decodedStorageSet(from: collapsedCheckoutKeysStorage)
    hasHydratedCollapsedState = true
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

  func syncCollapsedProjects(from rawValue: String) {
    guard hasHydratedCollapsedState else {
      return
    }

    let decoded = decodedStorageSet(from: rawValue)
    guard decoded != collapsedProjectIDsState else {
      return
    }
    collapsedProjectIDsState = decoded
  }

  func syncCollapsedCheckouts(from rawValue: String) {
    guard hasHydratedCollapsedState else {
      return
    }

    let decoded = decodedStorageSet(from: rawValue)
    guard decoded != collapsedCheckoutKeysState else {
      return
    }
    collapsedCheckoutKeysState = decoded
  }

  func setProjectCollapsed(
    projectID: String,
    isCollapsed: Bool
  ) {
    hydrateCollapsedStateIfNeeded()

    if isCollapsed {
      collapsedProjectIDsState.insert(projectID)
    } else {
      collapsedProjectIDsState.remove(projectID)
    }

    let encoded = encodedStorageSet(collapsedProjectIDsState)
    if collapsedProjectIDsStorage != encoded {
      collapsedProjectIDsStorage = encoded
    }
  }

  func setCheckoutCollapsed(
    checkoutKey: String,
    isCollapsed: Bool
  ) {
    hydrateCollapsedStateIfNeeded()

    if isCollapsed {
      collapsedCheckoutKeysState.insert(checkoutKey)
    } else {
      collapsedCheckoutKeysState.remove(checkoutKey)
    }

    let encoded = encodedStorageSet(collapsedCheckoutKeysState)
    if collapsedCheckoutKeysStorage != encoded {
      collapsedCheckoutKeysStorage = encoded
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
