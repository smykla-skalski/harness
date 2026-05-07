import HarnessMonitorKit
import SwiftUI

struct SidebarSearchPresentationState {
  var isPresented = false
  var hasPendingFocusRequest = false

  mutating func requestPresentation(canPresent: Bool) -> Bool {
    guard canPresent else {
      hasPendingFocusRequest = true
      return false
    }
    isPresented = true
    return true
  }

  mutating func applyPendingPresentationIfNeeded(canPresent: Bool) -> Bool {
    guard canPresent, hasPendingFocusRequest else {
      return false
    }
    hasPendingFocusRequest = false
    isPresented = true
    return true
  }
}

struct SidebarSearchHost: View {
  let store: HarnessMonitorStore
  let controls: HarnessMonitorStore.SessionControlsSlice
  let projection: HarnessMonitorStore.SessionProjectionSlice
  let searchResults: HarnessMonitorStore.SessionSearchResultsSlice
  let sidebarUI: HarnessMonitorStore.SidebarUISlice
  let canPresentSearch: Bool
  let interactionRelay: ContentInteractionRelay
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration
  let fontScale: CGFloat
  let sidebarSessionRowDisplayMode: HarnessMonitorSidebarSessionRowDisplayMode
  let collapsedCheckoutKeys: Set<String>
  let setCheckoutCollapsed: (String, Bool) -> Void

  @AppStorage(HarnessMonitorMCPSettingsDefaults.registryHostEnabledKey)
  private var mcpRegistryHostEnabled = HarnessMonitorMCPSettingsDefaults
    .registryHostEnabledDefault
  @State private var searchPresentationState = SidebarSearchPresentationState()
  @State private var searchFocusDispatcher = HarnessSidebarSearchFocusDispatcher()

  private var profilingAttributes: [String: String] {
    [
      "harness.view.session_filter": controls.sessionFilter.rawValue,
      "harness.view.focus_filter": controls.sessionFocusFilter.rawValue,
      "harness.view.sort_order": controls.sessionSortOrder.rawValue,
      "harness.view.filtered_sessions": "\(searchResults.filteredSessionCount)",
      "harness.view.total_sessions": "\(searchResults.totalSessionCount)",
      "harness.view.search_presented": searchPresentationState.isPresented ? "true" : "false",
    ]
  }

  private var searchText: Binding<String> {
    Binding(
      get: { store.searchText },
      set: { store.searchText = $0 }
    )
  }

  private var searchPresentation: Binding<Bool> {
    Binding(
      get: { searchPresentationState.isPresented },
      set: { searchPresentationState.isPresented = $0 }
    )
  }

  private var searchFocusAction: HarnessSidebarSearchFocus? {
    guard canPresentSearch else {
      return nil
    }
    return HarnessSidebarSearchFocus(
      isAvailable: true,
      menuLabel: .findInSessions,
      dispatcher: searchFocusDispatcher
    )
  }

  private var sidebarFooterStateMarkerValue: String {
    SidebarFooterStatusStripState(
      daemonOwnership: store.daemonOwnership,
      bridgeRunning: store.daemonStatus?.manifest?.hostBridge.running == true,
      mcpStatus: store.mcpStatus,
      isMCPRegistryHostEnabled: mcpRegistryHostEnabled
    ).stateMarkerValue
  }

  var body: some View {
    ViewBodySignposter.trace(Self.self, "SidebarView", attributes: profilingAttributes) {
      SidebarSessionListColumn(
        store: store,
        controls: controls,
        projection: projection,
        searchResults: searchResults,
        sidebarUI: sidebarUI,
        interactionRelay: interactionRelay,
        dateTimeConfiguration: dateTimeConfiguration,
        fontScale: fontScale,
        sidebarSessionRowDisplayMode: sidebarSessionRowDisplayMode,
        collapsedCheckoutKeys: collapsedCheckoutKeys,
        setCheckoutCollapsed: setCheckoutCollapsed
      )
      .listStyle(.sidebar)
      .scrollEdgeEffectStyle(.soft, for: .top)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        SidebarFooterAccessoryBridge(
          sidebarUI: sidebarUI,
          daemonOwnership: store.daemonOwnership,
          bridgeRunning: store.daemonStatus?.manifest?.hostBridge.running == true,
          mcpStatus: store.mcpStatus,
          isMCPRegistryHostEnabled: mcpRegistryHostEnabled
        )
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .accessibilityFrameMarker(HarnessMonitorAccessibility.sidebarShellFrame)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarRoot)
      .overlay {
        Group {
          SidebarFilterStateMarker(
            controls: controls,
            searchResults: searchResults,
            isSidebarSearchPresented: searchPresentationState.isPresented
          )
          AccessibilityTextMarker(
            identifier: HarnessMonitorAccessibility.sidebarFooterState,
            text: sidebarFooterStateMarkerValue
          )
        }
      }
      .searchable(
        text: searchText,
        isPresented: searchPresentation,
        placement: .sidebar,
        prompt: Text("Search sessions, projects, leaders")
      )
      .toolbar {
        SidebarToolbarFilterToolbarItem(store: store, controls: controls)
      }
      .harnessFocusedSceneValue(\.harnessSidebarSearchFocusAction, searchFocusAction)
      .task {
        searchFocusDispatcher.handler = {
          _ = searchPresentationState.requestPresentation(canPresent: true)
        }
      }
      .onChange(of: canPresentSearch, initial: true) { _, canPresent in
        applyPendingSearchPresentationIfNeeded(canPresent: canPresent)
      }
      .onSubmit(of: .search) {
        submitSearch()
      }
    }
  }

  private func applyPendingSearchPresentationIfNeeded(canPresent: Bool) {
    _ = searchPresentationState.applyPendingPresentationIfNeeded(canPresent: canPresent)
  }

  private func submitSearch() {
    store.flushPendingSearchRebuild()
    guard store.sidebarUI.isPersistenceAvailable else {
      return
    }
    _ = store.recordSearch(store.searchText)
  }
}
