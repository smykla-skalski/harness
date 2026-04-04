import HarnessMonitorKit
import Observation
import SwiftData
import SwiftUI

struct SidebarFilterContainer: View {
  @Bindable var store: HarnessMonitorStore
  @Query(sort: \RecentSearch.lastUsedAt, order: .reverse)
  private var recentSearches: [RecentSearch]
  @State private var draftSearchText = ""
  @AppStorage("harnessMonitor.sidebar.filtersExpanded")
  private var isExpanded = true

  init(store: HarnessMonitorStore) {
    self.store = store
  }

  private var recentSearchQueries: [String] {
    Array(recentSearches.prefix(5).map(\.query))
  }

  var body: some View {
    SidebarFilterSection(
      filteredSessionCount: store.filteredSessionCount,
      totalSessionCount: store.sessions.count,
      searchText: store.searchText,
      draftSearchText: $draftSearchText,
      sessionFilter: store.sessionFilter,
      sessionFocusFilter: store.sessionFocusFilter,
      sessionSortOrder: $store.sessionSortOrder,
      isPersistenceAvailable: store.isPersistenceAvailable,
      recentSearchQueries: recentSearchQueries,
      isExpanded: isExpanded,
      resetFilters: store.resetFilters,
      toggleExpanded: { isExpanded.toggle() },
      submitSearch: submitSearch,
      setSessionFilter: setSessionFilter(_:),
      setSessionFocusFilter: setSessionFocusFilter(_:),
      applyRecentSearch: applyRecentSearch(_:),
      clearSearchHistory: clearSearchHistory
    )
    .task(id: draftSearchText) {
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled else { return }
      store.searchText = draftSearchText
    }
    .onAppear {
      draftSearchText = store.searchText
    }
    .onChange(of: store.searchText) { _, newValue in
      if draftSearchText != newValue {
        draftSearchText = newValue
      }
    }
  }

  private func submitSearch() {
    store.searchText = draftSearchText
    _ = store.recordSearch(draftSearchText)
  }

  private func setSessionFilter(_ filter: HarnessMonitorStore.SessionFilter) {
    store.sessionFilter = filter
  }

  private func setSessionFocusFilter(_ filter: SessionFocusFilter) {
    store.sessionFocusFilter = filter
  }

  private func applyRecentSearch(_ query: String) {
    draftSearchText = query
    store.searchText = query
  }

  private func clearSearchHistory() {
    _ = store.clearSearchHistory()
  }
}

#Preview("Sidebar Filters - Observed Search") {
  let store = sidebarFilterPreviewStore(
    searchText: "observer",
    sessionFilter: .all,
    sessionFocusFilter: .observed,
    scenario: .sidebarOverflow
  )

  SidebarFilterContainer(store: store)
    .modelContainer(HarnessMonitorPreviewStoreFactory.previewContainer)
    .padding(16)
    .frame(width: 340)
}

#Preview("Sidebar Filters - Default") {
  let store = sidebarFilterPreviewStore(
    searchText: "",
    sessionFilter: .active,
    sessionFocusFilter: .all,
    scenario: .dashboardLoaded
  )

  SidebarFilterContainer(store: store)
    .modelContainer(HarnessMonitorPreviewStoreFactory.previewContainer)
    .padding(16)
    .frame(width: 340)
}

@MainActor
private func sidebarFilterPreviewStore(
  searchText: String,
  sessionFilter: HarnessMonitorStore.SessionFilter,
  sessionFocusFilter: SessionFocusFilter,
  scenario: HarnessMonitorPreviewStoreFactory.Scenario
) -> HarnessMonitorStore {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(
    for: scenario,
    modelContainer: HarnessMonitorPreviewStoreFactory.previewContainer
  )
  store.searchText = searchText
  store.sessionFilter = sessionFilter
  store.sessionFocusFilter = sessionFocusFilter
  return store
}
