import HarnessMonitorKit
import Observation
import SwiftData
import SwiftUI

struct SidebarFilterContainer: View {
  let store: HarnessMonitorStore
  @Bindable var sessionIndex: HarnessMonitorStore.SessionIndexSlice
  @Bindable var sidebarUI: HarnessMonitorStore.SidebarUISlice
  @Query(sort: \RecentSearch.lastUsedAt, order: .reverse)
  private var recentSearches: [RecentSearch]
  @State private var draftSearchText = ""
  @AppStorage("harnessMonitor.sidebar.filtersExpanded")
  private var isExpanded = true

  init(
    store: HarnessMonitorStore,
    sessionIndex: HarnessMonitorStore.SessionIndexSlice,
    sidebarUI: HarnessMonitorStore.SidebarUISlice
  ) {
    self.store = store
    self.sessionIndex = sessionIndex
    self.sidebarUI = sidebarUI
  }

  private var recentSearchQueries: [String] {
    Array(recentSearches.prefix(5).map(\.query))
  }

  var body: some View {
    SidebarFilterSection(
      store: store,
      sessionIndex: sessionIndex,
      sidebarUI: sidebarUI,
      draftSearchText: $draftSearchText,
      recentSearchQueries: recentSearchQueries,
      isExpanded: isExpanded,
      toggleExpanded: { isExpanded.toggle() }
    )
    .task(id: draftSearchText) {
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled else { return }
      sessionIndex.searchText = draftSearchText
    }
    .onAppear {
      draftSearchText = sessionIndex.searchText
    }
    .onChange(of: sessionIndex.searchText) { _, newValue in
      if draftSearchText != newValue {
        draftSearchText = newValue
      }
    }
  }
}

#Preview("Sidebar Filters - Observed Search") {
  let store = sidebarFilterPreviewStore(
    searchText: "observer",
    sessionFilter: .all,
    sessionFocusFilter: .observed,
    scenario: .sidebarOverflow
  )

  SidebarFilterContainer(
    store: store,
    sessionIndex: store.sessionIndex,
    sidebarUI: store.sidebarUI
  )
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

  SidebarFilterContainer(
    store: store,
    sessionIndex: store.sessionIndex,
    sidebarUI: store.sidebarUI
  )
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
