import HarnessMonitorKit
import SwiftUI

struct SidebarView: View {
  let store: HarnessMonitorStore
  let controls: HarnessMonitorStore.SessionControlsSlice
  let projection: HarnessMonitorStore.SessionProjectionSlice
  let searchResults: HarnessMonitorStore.SessionSearchResultsSlice
  let sidebarUI: HarnessMonitorStore.SidebarUISlice
  let isSidebarSearchPresented: Bool
  @Environment(\.isSearching)
  private var isSearching
  @Environment(\.harnessDateTimeConfiguration)
  var dateTimeConfiguration
  @Environment(\.fontScale)
  var fontScale

  @State private var collapsedCheckoutKeys: Set<String> = []

  private var profilingAttributes: [String: String] {
    [
      "harness.view.session_filter": controls.sessionFilter.rawValue,
      "harness.view.focus_filter": controls.sessionFocusFilter.rawValue,
      "harness.view.sort_order": controls.sessionSortOrder.rawValue,
      "harness.view.filtered_sessions": "\(searchResults.filteredSessionCount)",
      "harness.view.total_sessions": "\(searchResults.totalSessionCount)",
    ]
  }

  private var showsSearchAccessoryBar: Bool {
    SidebarFilterVisibilityPolicy.showsControls(
      for: controls,
      isSearchActive: isSearching
    )
  }

  var body: some View {
    ViewBodySignposter.trace(Self.self, "SidebarView", attributes: profilingAttributes) {
      SidebarSessionListColumn(
        store: store,
        controls: controls,
        projection: projection,
        searchResults: searchResults,
        sidebarUI: sidebarUI,
        showsSearchControls: showsSearchAccessoryBar,
        dateTimeConfiguration: dateTimeConfiguration,
        fontScale: fontScale,
        collapsedCheckoutKeys: collapsedCheckoutKeys,
        setCheckoutCollapsed: setCheckoutCollapsed
      )
      .listStyle(.sidebar)
      .scrollEdgeEffectStyle(.soft, for: .top)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        SidebarFooterMetricsBridge(sidebarUI: sidebarUI)
      }
      .toolbar {
        SidebarToolbarNewSessionToolbarItem(store: store)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .accessibilityFrameMarker(HarnessMonitorAccessibility.sidebarShellFrame)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarRoot)
      .overlay {
        SidebarFilterStateMarker(
          controls: controls,
          searchResults: searchResults,
          isSidebarSearchPresented: isSidebarSearchPresented,
          isSearchActive: isSearching
        )
      }
    }
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

private struct SidebarToolbarNewSessionToolbarItem: ToolbarContent {
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

private struct SidebarFilterStateMarker: View {
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

private struct SidebarSessionListColumn: View {
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
    isSearchActive: Bool
  ) -> Bool {
    isSearchActive || hasActiveFilters(in: controls)
  }
}

private struct SidebarFooterMetricsBridge: View {
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
