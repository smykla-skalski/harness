import HarnessMonitorKit
import SwiftUI

struct SidebarView: View {
  let store: HarnessMonitorStore
  let controls: HarnessMonitorStore.SessionControlsSlice
  let projection: HarnessMonitorStore.SessionProjectionSlice
  let searchResults: HarnessMonitorStore.SessionSearchResultsSlice
  let sidebarUI: HarnessMonitorStore.SidebarUISlice
  let canPresentSearch: Bool
  @Environment(\.harnessDateTimeConfiguration)
  var dateTimeConfiguration
  @Environment(\.fontScale)
  var fontScale

  @State private var collapsedCheckoutKeys: Set<String> = []

  var body: some View {
    SidebarSearchHost(
      store: store,
      controls: controls,
      projection: projection,
      searchResults: searchResults,
      sidebarUI: sidebarUI,
      canPresentSearch: canPresentSearch,
      dateTimeConfiguration: dateTimeConfiguration,
      fontScale: fontScale,
      collapsedCheckoutKeys: collapsedCheckoutKeys,
      setCheckoutCollapsed: setCheckoutCollapsed
    )
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
}

struct SidebarToolbarNewSessionToolbarItem: ToolbarContent {
  let store: HarnessMonitorStore

  var body: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      Button {
        store.presentedSheet = .newSession
      } label: {
        Label("New Session", systemImage: "plus")
      }
      .help("Start a new session")
      .disabled(store.connectionState != .online)
      .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarNewSessionButton)
    }
  }
}

struct SidebarFilterStateMarker: View {
  let controls: HarnessMonitorStore.SessionControlsSlice
  let searchResults: HarnessMonitorStore.SessionSearchResultsSlice
  let isSidebarSearchPresented: Bool
  let isSearchActive: Bool

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

  private var sidebarSearchStateValue: String {
    let isVisible = SidebarFilterVisibilityPolicy.showsControls(
      for: controls,
      isSearchPresented: isSidebarSearchPresented,
      isSearchActive: isSearchActive
    )
    return [
      "presented=\(isSidebarSearchPresented)",
      "active=\(isSearchActive)",
      "visible=\(isVisible)",
    ].joined(separator: ", ")
  }

  var body: some View {
    if HarnessMonitorUITestEnvironment.searchMarkersEnabled {
      Group {
        AccessibilityTextMarker(
          identifier: HarnessMonitorAccessibility.sidebarFilterState,
          text: sidebarFilterStateValue
        )
        AccessibilityTextMarker(
          identifier: HarnessMonitorAccessibility.sidebarSearchState,
          text: sidebarSearchStateValue
        )
      }
    }
  }
}

struct SidebarSessionListColumn: View {
  let store: HarnessMonitorStore
  let controls: HarnessMonitorStore.SessionControlsSlice
  let projection: HarnessMonitorStore.SessionProjectionSlice
  let searchResults: HarnessMonitorStore.SessionSearchResultsSlice
  let sidebarUI: HarnessMonitorStore.SidebarUISlice
  let showsSearchControls: Bool
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration
  let fontScale: CGFloat
  let collapsedCheckoutKeys: Set<String>
  let setCheckoutCollapsed: (String, Bool) -> Void

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

  private var renderState: SidebarSessionListRenderState {
    SidebarSessionListRenderState(
      sessionCatalog: store.sessionIndex.catalog,
      projectionGroups: projection.groupedSessions,
      searchPresentation: searchResults.presentationState,
      searchVisibleSessionIDs: searchResults.visibleSessionIDs,
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
      if showsSearchControls {
        SidebarSearchControlsSection(
          store: store,
          controls: controls
        )
      }
      SidebarSessionListContent(
        store: store,
        renderState: renderState,
        toggleBookmark: { sessionID, projectID in
          store.toggleBookmark(sessionId: sessionID, projectId: projectID)
        },
        setCheckoutCollapsed: setCheckoutCollapsed
      )
    }
    .accessibilityFrameMarker(HarnessMonitorAccessibility.sidebarSessionListContent)
    .accessibilityTestProbe(
      HarnessMonitorAccessibility.sidebarSessionListState,
      label: renderState.groupedStateAccessibilityLabel
    )
  }
}

@MainActor
enum SidebarFilterVisibilityPolicy {
  static func hasActiveFilters(
    in controls: HarnessMonitorStore.SessionControlsSlice
  ) -> Bool {
    !controls.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || controls.sessionFilter != .all
      || controls.sessionFocusFilter != .all
      || controls.sessionSortOrder != .recentActivity
  }

  static func showsControls(
    for controls: HarnessMonitorStore.SessionControlsSlice,
    isSearchPresented: Bool,
    isSearchActive: Bool
  ) -> Bool {
    isSearchPresented || isSearchActive || hasActiveFilters(in: controls)
  }
}

struct SidebarFooterMetricsBridge: View {
  let sidebarUI: HarnessMonitorStore.SidebarUISlice

  private var summary: SidebarFooterSummary {
    SidebarFooterSummary(
      projectCount: sidebarUI.projectCount,
      worktreeCount: sidebarUI.worktreeCount,
      sessionCount: sidebarUI.sessionCount,
      openWorkCount: sidebarUI.openWorkCount,
      blockedCount: sidebarUI.blockedCount
    )
  }

  var body: some View {
    SidebarFooterAccessory(
      metrics: sidebarUI.connectionMetrics,
      summary: summary
    )
  }
}
