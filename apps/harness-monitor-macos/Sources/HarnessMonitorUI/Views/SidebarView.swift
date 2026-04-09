import HarnessMonitorKit
import Observation
import SwiftData
import SwiftUI

struct SidebarView: View {
  let store: HarnessMonitorStore
  let sessionIndex: HarnessMonitorStore.SessionIndexSlice
  @Bindable var searchController: SidebarSearchController
  @Query(sort: \RecentSearch.lastUsedAt, order: .reverse)
  private var recentSearches: [RecentSearch]
  @State private var sidebarSelectedSessionID: String?
  @State private var draftSidebarSearchText = ""
  @State private var isSidebarSearchPresented = false

  @SceneStorage("sidebar.collapsed-project-ids")
  var collapsedProjectIDsStorage = ""
  @SceneStorage("sidebar.collapsed-checkout-keys")
  var collapsedCheckoutKeysStorage = ""

  init(
    store: HarnessMonitorStore,
    sessionIndex: HarnessMonitorStore.SessionIndexSlice,
    searchController: SidebarSearchController
  ) {
    self.store = store
    self.sessionIndex = sessionIndex
    self.searchController = searchController
    _sidebarSelectedSessionID = State(initialValue: store.selectedSessionID)
    _draftSidebarSearchText = State(initialValue: store.searchText)
  }

  var sidebarRowInsets: EdgeInsets {
    EdgeInsets(
      top: HarnessMonitorTheme.spacingXS,
      leading: HarnessMonitorTheme.sectionSpacing,
      bottom: HarnessMonitorTheme.spacingXS,
      trailing: HarnessMonitorTheme.sectionSpacing
    )
  }

  var collapsedProjectIDs: Set<String> {
    storageSet(from: collapsedProjectIDsStorage)
  }

  var collapsedCheckoutKeys: Set<String> {
    storageSet(from: collapsedCheckoutKeysStorage)
  }

  private var recentSearchQueries: [String] {
    guard store.isPersistenceAvailable else {
      return []
    }
    return Array(recentSearches.prefix(5).map(\.query))
  }

  private var hasActiveSidebarFilters: Bool {
    !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || store.sessionFilter != .active
      || store.sessionFocusFilter != .all
      || store.sessionSortOrder != .recentActivity
  }

  private var sidebarFilterStateValue: String {
    [
      "status=\(store.sessionFilter.rawValue)",
      "focus=\(store.sessionFocusFilter.rawValue)",
      "sort=\(store.sessionSortOrder.rawValue)",
      "visible=\(store.filteredSessionCount)",
      "total=\(store.sessions.count)",
      "search=\(store.searchText)",
    ].joined(separator: ", ")
  }

  var body: some View {
    List(selection: $sidebarSelectedSessionID) {
      sidebarContent
    }
    .listStyle(.sidebar)
    .environment(\.defaultMinListRowHeight, 1)
    .scrollEdgeEffectStyle(.soft, for: .top)
    .searchable(
      text: $draftSidebarSearchText,
      isPresented: $isSidebarSearchPresented,
      placement: .sidebar,
      prompt: "Search sessions, projects, leaders"
    )
    .safeAreaInset(edge: .top, spacing: 0) {
      sidebarHeader
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      SidebarFooterAccessory(metrics: store.connectionMetrics)
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        SidebarToolbarFilterMenu(
          sessionFilter: store.sessionFilter,
          sessionFocusFilter: store.sessionFocusFilter,
          sessionSortOrder: store.sessionSortOrder,
          hasActiveFilters: hasActiveSidebarFilters,
          setSessionFilter: setSessionFilter,
          setSessionFocusFilter: setSessionFocusFilter,
          setSessionSortOrder: setSessionSortOrder,
          clearFilters: clearSidebarFilters
        )
      }
    }
    .onAppear {
      sidebarSelectedSessionID = store.selectedSessionID
      draftSidebarSearchText = store.searchText
    }
    .task(id: draftSidebarSearchText) {
      let nextValue = draftSidebarSearchText
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled else { return }
      if store.searchText != nextValue {
        store.searchText = nextValue
      }
    }
    .onChange(of: store.searchText) { _, newValue in
      if draftSidebarSearchText != newValue {
        draftSidebarSearchText = newValue
      }
    }
    .onChange(of: sidebarSelectedSessionID) { _, newValue in
      guard store.selectedSessionID != newValue else {
        return
      }
      store.selectSessionFromList(newValue)
    }
    .onChange(of: store.selectedSessionID) { _, newValue in
      guard sidebarSelectedSessionID != newValue else {
        return
      }
      sidebarSelectedSessionID = newValue
    }
    .onChange(of: searchController.focusRequestToken) { _, _ in
      focusSidebarSearch()
    }
    .onSubmit(of: .search) {
      if store.isPersistenceAvailable {
        _ = store.recordSearch(draftSidebarSearchText)
      }
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
    switch emptyState {
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
      if let firstGroup = sessionIndex.groupedSessions.first {
        projectSection(for: firstGroup)
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarSessionList)
          .accessibilityFrameMarker(HarnessMonitorAccessibility.sidebarSessionListContent)

        ForEach(Array(sessionIndex.groupedSessions.dropFirst())) { group in
          projectSection(for: group)
        }
      }
    }
  }

  private var sidebarHeader: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      DaemonStatusCard(
        connectionState: store.connectionState,
        isBusy: store.isBusy,
        isRefreshing: store.isRefreshing,
        isLaunchAgentInstalled: store.daemonStatus?.launchAgent.installed == true,
        startDaemon: startDaemon,
        stopDaemon: stopDaemon,
        installLaunchAgent: installLaunchAgent
      )

      if !recentSearchQueries.isEmpty {
        sidebarRecentSearches
      }
    }
    .padding(.horizontal, HarnessMonitorTheme.sectionSpacing)
    .padding(.top, HarnessMonitorTheme.spacingXL)
    .padding(.bottom, HarnessMonitorTheme.sectionSpacing)
  }

  func storageSet(from rawValue: String) -> Set<String> {
    Set(
      rawValue
        .split(separator: "\n")
        .map(String.init)
        .filter { !$0.isEmpty }
    )
  }

  func updateStorageSet(
    _ storage: inout String,
    entry: String,
    include: Bool
  ) {
    var values = storageSet(from: storage)
    if include {
      values.insert(entry)
    } else {
      values.remove(entry)
    }
    storage = values.sorted().joined(separator: "\n")
  }

  private func startDaemon() async {
    await store.startDaemon()
  }

  private func stopDaemon() async {
    await store.stopDaemon()
  }

  private func installLaunchAgent() async {
    await store.installLaunchAgent()
  }

  private func setSessionFilter(_ filter: HarnessMonitorStore.SessionFilter) {
    store.sessionFilter = filter
  }

  private func setSessionFocusFilter(_ filter: SessionFocusFilter) {
    store.sessionFocusFilter = filter
  }

  private func setSessionSortOrder(_ order: SessionSortOrder) {
    store.sessionSortOrder = order
  }

  private func clearSidebarFilters() {
    draftSidebarSearchText = ""
    store.resetFilters()
    store.sessionSortOrder = .recentActivity
  }

  private func applyRecentSearch(_ query: String) {
    draftSidebarSearchText = query
    store.searchText = query
    focusSidebarSearch()
    if store.isPersistenceAvailable {
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

        if store.isPersistenceAvailable {
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

  private var emptyState: SidebarEmptyStateKind {
    if store.sessions.isEmpty {
      return .noSessions
    }
    if sessionIndex.groupedSessions.isEmpty {
      return .noMatches
    }
    return .sessionsAvailable
  }

  private func focusSidebarSearch() {
    guard !isSidebarSearchPresented else {
      isSidebarSearchPresented = false
      Task { @MainActor in
        isSidebarSearchPresented = true
      }
      return
    }
    isSidebarSearchPresented = true
  }
}

private enum SidebarEmptyStateKind {
  case noSessions
  case noMatches
  case sessionsAvailable
}
