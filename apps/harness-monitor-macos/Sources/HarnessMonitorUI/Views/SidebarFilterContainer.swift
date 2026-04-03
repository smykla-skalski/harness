import HarnessMonitorKit
import Observation
import SwiftData
import SwiftUI

struct SidebarFilterContainer: View {
  @Bindable var store: HarnessMonitorStore
  @Query(sort: \RecentSearch.lastUsedAt, order: .reverse)
  private var recentSearches: [RecentSearch]
  @State private var draftSearchText = ""

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
      resetFilters: store.resetFilters,
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
