import HarnessMonitorKit
import Observation
import SwiftData
import SwiftUI

struct SidebarView: View {
  let store: HarnessMonitorStore
  @Bindable var sessionIndex: HarnessMonitorStore.SessionIndexSlice
  @Bindable var sidebarUI: HarnessMonitorStore.SidebarUISlice
  @Query(sort: \RecentSearch.lastUsedAt, order: .reverse)
  private var recentSearches: [RecentSearch]

  @SceneStorage("sidebar.collapsed-project-ids")
  var collapsedProjectIDsStorage = ""
  @SceneStorage("sidebar.collapsed-checkout-keys")
  var collapsedCheckoutKeysStorage = ""

  init(
    store: HarnessMonitorStore,
    sessionIndex: HarnessMonitorStore.SessionIndexSlice,
    sidebarUI: HarnessMonitorStore.SidebarUISlice
  ) {
    self.store = store
    self.sessionIndex = sessionIndex
    self.sidebarUI = sidebarUI
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
      get: { sessionIndex.searchText },
      set: { newValue in
        guard sessionIndex.searchText != newValue else {
          return
        }
        sessionIndex.searchText = newValue
      }
    )
  }

  private var hasActiveSidebarFilters: Bool {
    !sessionIndex.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || sessionIndex.sessionFilter != .active
      || sessionIndex.sessionFocusFilter != .all
      || sessionIndex.sessionSortOrder != .recentActivity
  }

  private var sidebarFilterStateValue: String {
    [
      "status=\(sessionIndex.sessionFilter.rawValue)",
      "focus=\(sessionIndex.sessionFocusFilter.rawValue)",
      "sort=\(sessionIndex.sessionSortOrder.rawValue)",
      "visible=\(sessionIndex.filteredSessionCount)",
      "total=\(sessionIndex.sessions.count)",
      "search=\(sessionIndex.searchText)",
    ].joined(separator: ", ")
  }

  var body: some View {
    List(selection: sidebarSelection) {
      sidebarContent
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
      ToolbarItem(placement: .primaryAction) {
        SidebarToolbarFilterMenu(
          sessionFilter: sessionIndex.sessionFilter,
          sessionFocusFilter: sessionIndex.sessionFocusFilter,
          sessionSortOrder: sessionIndex.sessionSortOrder,
          hasActiveFilters: hasActiveSidebarFilters,
          setSessionFilter: setSessionFilter,
          setSessionFocusFilter: setSessionFocusFilter,
          setSessionSortOrder: setSessionSortOrder,
          clearFilters: clearSidebarFilters
        )
      }
    }
    .onSubmit(of: .search) {
      if sidebarUI.isPersistenceAvailable {
        _ = store.recordSearch(sessionIndex.searchText)
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
        connectionState: sidebarUI.connectionState,
        isBusy: sidebarUI.isBusy,
        isRefreshing: sidebarUI.isRefreshing,
        isLaunchAgentInstalled: sidebarUI.isLaunchAgentInstalled,
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
    sessionIndex.sessionFilter = filter
  }

  private func setSessionFocusFilter(_ filter: SessionFocusFilter) {
    sessionIndex.sessionFocusFilter = filter
  }

  private func setSessionSortOrder(_ order: SessionSortOrder) {
    sessionIndex.sessionSortOrder = order
  }

  private func clearSidebarFilters() {
    sessionIndex.searchText = ""
    sessionIndex.sessionFilter = .active
    sessionIndex.sessionFocusFilter = .all
    sessionIndex.sessionSortOrder = .recentActivity
  }

  private func applyRecentSearch(_ query: String) {
    sessionIndex.searchText = query
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

  private var emptyState: HarnessMonitorStore.SidebarEmptyState {
    sidebarUI.emptyState
  }
}
