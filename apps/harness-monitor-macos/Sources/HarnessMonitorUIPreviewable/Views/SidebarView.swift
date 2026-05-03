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

struct SidebarToolbarCreateMenuToolbarItem: ToolbarContent {
  let store: HarnessMonitorStore
  let canCreateTask: Bool

  private var createMenuAccessibilityValue: String {
    canCreateTask
      ? "New Agent and New Task available"
      : "New Agent available. New Task unavailable until a writable session is selected"
  }

  var body: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      SidebarCreateMenu(
        store: store,
        canCreateTask: canCreateTask,
        menuStateValue: createMenuAccessibilityValue
      )
    }
  }
}

private struct SidebarCreateMenu: View {
  let store: HarnessMonitorStore
  let canCreateTask: Bool
  let menuStateValue: String
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Menu {
      Button("New Agent", action: openNewAgent)
        .harnessMCPMenuItem(
          HarnessMonitorAccessibility.sidebarCreateMenuNewAgentItem,
          label: "New Agent"
        )

      Button("New Task", action: openNewTask)
        .disabled(!canCreateTask)
        .harnessMCPMenuItem(
          HarnessMonitorAccessibility.sidebarCreateMenuNewTaskItem,
          label: "New Task",
          enabled: canCreateTask
        )
    } label: {
      Label("Create", systemImage: "plus")
    }
    .help("Create agent or task")
    .menuIndicator(.hidden)
    .accessibilityLabel("Create")
    .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarCreateMenuButton)
    .accessibilityFrameMarker(HarnessMonitorAccessibility.sidebarCreateMenuButtonFrame)
    .harnessMCPButton(
      HarnessMonitorAccessibility.sidebarCreateMenuButton,
      label: "Create",
      value: menuStateValue
    )
  }

  private func openNewAgent() {
    store.requestWorkspaceCreateEntryPoint(.agent)
    openWindow(id: HarnessMonitorWindowID.workspace)
  }

  private func openNewTask() {
    store.requestCreateTaskSheet()
  }
}

struct SidebarToolbarFilterToolbarItem: ToolbarContent {
  let store: HarnessMonitorStore
  let controls: HarnessMonitorStore.SessionControlsSlice

  var body: some ToolbarContent {
    ToolbarItem(placement: .automatic) {
      SidebarFilterMenu(store: store, controls: controls)
    }
  }
}

struct SidebarFilterStateMarker: View {
  let controls: HarnessMonitorStore.SessionControlsSlice
  let searchResults: HarnessMonitorStore.SessionSearchResultsSlice
  let isSidebarSearchPresented: Bool

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
    [
      "presented=\(isSidebarSearchPresented)",
      "active=\(isSidebarSearchPresented)",
      "visible=true",
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
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration
  let fontScale: CGFloat
  let collapsedCheckoutKeys: Set<String>
  let setCheckoutCollapsed: (String, Bool) -> Void

  private var sidebarSelection: Binding<String?> {
    Binding(
      get: { renderedSidebarSelectionID },
      set: { newValue in
          HarnessMonitorUITestTrace.record(
            component: "sidebar.selection-binding",
            event: "set",
            details: [
              "new_value": newValue ?? "nil",
              "sidebar_selected_session_id": sidebarUI.selectedSessionID ?? "nil",
              "rendered_selection_id": renderedSidebarSelectionID ?? "nil"
            ]
          )
          if newValue == nil, shouldIgnoreFilteredSidebarDeselection {
            HarnessMonitorUITestTrace.record(
              component: "sidebar.selection-binding",
              event: "ignored-nil-clear",
              details: [
                "sidebar_selected_session_id": sidebarUI.selectedSessionID ?? "nil",
                "rendered_selection_id": renderedSidebarSelectionID ?? "nil"
              ]
            )
            return
          }
          guard sidebarUI.selectedSessionID != newValue else {
            HarnessMonitorUITestTrace.record(
              component: "sidebar.selection-binding",
              event: "ignored-duplicate",
              details: [
                "new_value": newValue ?? "nil"
              ]
            )
            return
          }
          store.selectSessionFromList(newValue)
        }
    )
  }

  private var shouldIgnoreFilteredSidebarDeselection: Bool {
    guard sidebarUI.selectedSessionID != nil else {
      return false
    }
    return renderedSidebarSelectionID == nil
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
