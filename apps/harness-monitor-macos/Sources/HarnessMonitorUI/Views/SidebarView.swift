import HarnessMonitorKit
import Observation
import SwiftData
import SwiftUI

struct SidebarView: View {
  let store: HarnessMonitorStore
  @Bindable var controls: HarnessMonitorStore.SessionControlsSlice
  @Bindable var projection: HarnessMonitorStore.SessionProjectionSlice
  @Bindable var sidebarUI: HarnessMonitorStore.SidebarUISlice
  let sidebarVisible: Bool
  @Query(sort: \RecentSearch.lastUsedAt, order: .reverse)
  private var recentSearches: [RecentSearch]

  @SceneStorage("sidebar.collapsed-project-ids")
  var collapsedProjectIDsStorage = ""
  @SceneStorage("sidebar.collapsed-checkout-keys")
  var collapsedCheckoutKeysStorage = ""
  @State private var collapsedProjectIDsState: Set<String> = []
  @State private var collapsedCheckoutKeysState: Set<String> = []
  @State private var hasHydratedCollapsedState = false

  init(
    store: HarnessMonitorStore,
    controls: HarnessMonitorStore.SessionControlsSlice,
    projection: HarnessMonitorStore.SessionProjectionSlice,
    sidebarUI: HarnessMonitorStore.SidebarUISlice,
    sidebarVisible: Bool
  ) {
    self.store = store
    self.controls = controls
    self.projection = projection
    self.sidebarUI = sidebarUI
    self.sidebarVisible = sidebarVisible
  }

  var sidebarRowInsets: EdgeInsets {
    EdgeInsets(
      top: HarnessMonitorTheme.spacingSM,
      leading: HarnessMonitorTheme.sectionSpacing,
      bottom: HarnessMonitorTheme.spacingSM,
      trailing: HarnessMonitorTheme.sectionSpacing
    )
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

  private var recentSearchQueries: [String] {
    guard sidebarUI.isPersistenceAvailable else {
      return []
    }
    return Array(recentSearches.prefix(5).map(\.query))
  }

  private var sidebarSelection: Binding<String?> {
    Binding(
      get: { sidebarUI.selectedSessionID },
      set: { newValue in
        guard sidebarUI.selectedSessionID != newValue else {
          return
        }
        store.selectSessionFromList(newValue)
      }
    )
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

  private var sidebarFilterStateValue: String {
    [
      "status=\(controls.sessionFilter.rawValue)",
      "focus=\(controls.sessionFocusFilter.rawValue)",
      "sort=\(controls.sessionSortOrder.rawValue)",
      "visible=\(projection.filteredSessionCount)",
      "total=\(projection.totalSessionCount)",
      "search=\(controls.searchText)",
    ].joined(separator: ", ")
  }

  var body: some View {
    List(selection: sidebarSelection) {
      sidebarContent
    }
    .transaction {
      $0.animation = nil
      $0.disablesAnimations = true
    }
    .listStyle(.sidebar)
    .environment(\.defaultMinListRowHeight, 1)
    .scrollEdgeEffectStyle(.soft, for: .top)
    .searchable(
      text: sidebarSearchText,
      placement: .sidebar,
      prompt: "Search sessions, projects, leaders"
    )
    .safeAreaInset(edge: .top, spacing: 0) {
      sidebarHeader
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      SidebarFooterAccessory(metrics: sidebarUI.connectionMetrics)
    }
    .toolbar {
      if sidebarVisible {
        ToolbarItem(placement: .primaryAction) {
          SidebarToolbarFilterMenu(
            store: store,
            sessionFilter: controls.sessionFilter,
            sessionFocusFilter: controls.sessionFocusFilter,
            sessionSortOrder: controls.sessionSortOrder,
            hasActiveFilters: hasActiveSidebarFilters
          )
        }
      }
    }
    .onSubmit(of: .search) {
      if sidebarUI.isPersistenceAvailable {
        _ = store.recordSearch(controls.searchText)
      }
    }
    .onAppear(perform: hydrateCollapsedStateIfNeeded)
    .onChange(of: collapsedProjectIDsStorage) { _, newValue in
      syncCollapsedProjects(from: newValue)
    }
    .onChange(of: collapsedCheckoutKeysStorage) { _, newValue in
      syncCollapsedCheckouts(from: newValue)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .foregroundStyle(HarnessMonitorTheme.ink)
    .accessibilityFrameMarker(HarnessMonitorAccessibility.sidebarShellFrame)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarRoot)
    .overlay {
      if HarnessMonitorUITestEnvironment.isEnabled {
        AccessibilityTextMarker(
          identifier: HarnessMonitorAccessibility.sidebarFilterState,
          text: sidebarFilterStateValue
        )
      }
    }
  }

  @ViewBuilder private var sidebarContent: some View {
    switch projection.emptyState {
    case .noSessions:
      SidebarEmptyState(
        title: "No sessions indexed yet",
        systemImage: "tray",
        message: "Start the daemon or refresh after launching a harness session."
      )
    case .noMatches:
      SidebarEmptyState(
        title: "No sessions match",
        systemImage: "magnifyingglass",
        message: "Try a broader search or clear filters."
      )
    case .sessionsAvailable:
      if let firstGroup = projection.groupedSessions.first {
        projectSection(for: firstGroup)
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarSessionList)
          .accessibilityFrameMarker(HarnessMonitorAccessibility.sidebarSessionListContent)

        ForEach(Array(projection.groupedSessions.dropFirst())) { group in
          projectSection(for: group)
        }
      }
    }
  }

  private var sidebarHeader: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      DaemonStatusCard(
        store: store,
        connectionState: sidebarUI.connectionState,
        isBusy: sidebarUI.isBusy,
        isRefreshing: sidebarUI.isRefreshing,
        isLaunchAgentInstalled: sidebarUI.isLaunchAgentInstalled
      )

      if !recentSearchQueries.isEmpty {
        sidebarRecentSearches
      }
    }
    .padding(.horizontal, HarnessMonitorTheme.sectionSpacing)
    .padding(.top, HarnessMonitorTheme.spacingXL)
    .padding(.bottom, HarnessMonitorTheme.sectionSpacing)
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
    if sidebarUI.isPersistenceAvailable {
      _ = store.recordSearch(query)
    }
  }

  @ViewBuilder private var sidebarRecentSearches: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      HStack {
        Text("Recent Searches")
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)

        Spacer()

        if sidebarUI.isPersistenceAvailable {
          Button("Clear") {
            _ = store.clearSearchHistory()
          }
          .harnessDismissButtonStyle()
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarClearSearchHistoryButton)
        }
      }

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: HarnessMonitorTheme.spacingXS) {
          ForEach(recentSearchQueries, id: \.self) { query in
            Button {
              applyRecentSearch(query)
            } label: {
              Text(query)
                .lineLimit(1)
                .padding(.horizontal, HarnessMonitorTheme.spacingSM)
                .padding(.vertical, HarnessMonitorTheme.spacingXS)
            }
            .harnessAccessoryButtonStyle()
          }
        }
      }
    }
  }

}
