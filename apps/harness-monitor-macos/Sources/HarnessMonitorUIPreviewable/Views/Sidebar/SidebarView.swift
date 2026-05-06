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
  @Environment(\.openWindow)
  private var openWindow

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
    store.requestWorkspaceCreateEntryPoint(
      .agent,
      sessionID: store.selectedSession?.session.sessionId
    )
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
  @State private var localSelection: Set<String>

  init(
    store: HarnessMonitorStore,
    controls: HarnessMonitorStore.SessionControlsSlice,
    projection: HarnessMonitorStore.SessionProjectionSlice,
    searchResults: HarnessMonitorStore.SessionSearchResultsSlice,
    sidebarUI: HarnessMonitorStore.SidebarUISlice,
    dateTimeConfiguration: HarnessMonitorDateTimeConfiguration,
    fontScale: CGFloat,
    collapsedCheckoutKeys: Set<String>,
    setCheckoutCollapsed: @escaping (String, Bool) -> Void
  ) {
    self.store = store
    self.controls = controls
    self.projection = projection
    self.searchResults = searchResults
    self.sidebarUI = sidebarUI
    self.dateTimeConfiguration = dateTimeConfiguration
    self.fontScale = fontScale
    self.collapsedCheckoutKeys = collapsedCheckoutKeys
    self.setCheckoutCollapsed = setCheckoutCollapsed
    _localSelection = State(
      initialValue: SidebarSessionListSelectionSync.selection(for: sidebarUI.selectedSessionID)
    )
  }

  private var visibleSessionIDs: Set<String> {
    Set(searchResults.visibleSessionIDs)
  }

  private var renderedSidebarSelection: Set<String> {
    SidebarSessionListSelectionSync.renderedSelection(
      from: localSelection,
      visibleSessionIDs: visibleSessionIDs
    )
  }

  private var sidebarSelection: Binding<Set<String>> {
    Binding(
      get: { renderedSidebarSelection },
      set: { newValue in
        let change = SidebarSessionListSelectionSync.resolve(
          previousSelection: localSelection,
          newRenderedSelection: newValue,
          visibleSessionIDs: visibleSessionIDs,
          storeSelectedSessionID: sidebarUI.selectedSessionID
        )
        HarnessMonitorUITestTrace.record(
          component: "sidebar.selection-binding",
          event: "set",
          details: [
            "new_count": "\(newValue.count)",
            "new_ids": newValue.sorted().joined(separator: ","),
            "sidebar_selected_session_id": sidebarUI.selectedSessionID ?? "nil",
            "rendered_selection_ids": renderedSidebarSelection.sorted().joined(separator: ","),
          ]
        )
        applySelectionChange(change)
      }
    )
  }

  private var renderState: SidebarSessionListRenderState {
    SidebarSessionListRenderState(
      sessionCatalog: store.sessionIndex.catalog,
      projectionGroups: projection.groupedSessions,
      searchPresentation: searchResults.presentationState,
      searchVisibleSessionIDs: searchResults.visibleSessionIDs,
      selectedSessionIDs: renderedSidebarSelection,
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
        activateSessionRow: activateSessionRow,
        toggleBookmark: { sessionID, projectID in
          store.toggleBookmark(sessionId: sessionID, projectId: projectID)
        },
        setCheckoutCollapsed: setCheckoutCollapsed
      )
    }
    .onChange(of: sidebarUI.selectedSessionID, initial: true) { _, newValue in
      syncSelectionFromStore(newValue)
    }
    .accessibilityFrameMarker(HarnessMonitorAccessibility.sidebarSessionListContent)
    .accessibilityTestProbe(
      HarnessMonitorAccessibility.sidebarSessionListState,
      label: renderState.groupedStateAccessibilityLabel
    )
  }

  private func activateSessionRow(_ sessionID: String) {
    let change = SidebarSessionListSelectionSync.semanticActivation(
      sessionID: sessionID,
      storeSelectedSessionID: sidebarUI.selectedSessionID
    )
    HarnessMonitorUITestTrace.record(
      component: "sidebar.selection-semantic-press",
      event: "activate",
      details: [
        "session_id": sessionID,
        "previous_ids": localSelection.sorted().joined(separator: ","),
        "store_selected_session_id": sidebarUI.selectedSessionID ?? "nil",
      ]
    )
    applySelectionChange(change)
  }

  private func syncSelectionFromStore(_ sessionID: String?) {
    let nextSelection = SidebarSessionListSelectionSync.selection(for: sessionID)
    guard localSelection != nextSelection else {
      return
    }
    HarnessMonitorUITestTrace.record(
      component: "sidebar.selection-store-sync",
      event: "applied",
      details: [
        "from_ids": localSelection.sorted().joined(separator: ","),
        "to_ids": nextSelection.sorted().joined(separator: ","),
        "store_selected_session_id": sessionID ?? "nil",
      ]
    )
    localSelection = nextSelection
  }

  private func applySelectionChange(_ change: SidebarSessionListSelectionChange) {
    localSelection = change.nextSelection
    switch change.storeSelection {
    case .unchanged:
      return
    case .cleared:
      if sidebarUI.selectedSessionID != nil {
        store.selectSessionFromList(nil)
      }
    case .selected(let sessionID):
      store.selectSessionFromList(sessionID)
    }
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

struct SidebarFooterAccessoryBridge: View {
  let sidebarUI: HarnessMonitorStore.SidebarUISlice
  let daemonOwnership: DaemonOwnership
  let bridgeRunning: Bool
  let mcpStatus: HarnessMonitorMCPStatusSnapshot
  let isMCPRegistryHostEnabled: Bool

  var body: some View {
    SidebarFooterAccessory(
      metrics: sidebarUI.connectionMetrics,
      daemonOwnership: daemonOwnership,
      bridgeRunning: bridgeRunning,
      mcpStatus: mcpStatus,
      isMCPRegistryHostEnabled: isMCPRegistryHostEnabled
    )
  }
}
