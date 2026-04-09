import HarnessMonitorKit
import SwiftData
import SwiftUI

private struct SidebarSelectionAnchor: Equatable {
  let sessionID: String?
  let visibleIndex: Int?

  init(
    selectedSessionID: String?,
    visibleSessionIDs: [String]
  ) {
    sessionID = selectedSessionID
    visibleIndex = selectedSessionID.flatMap { visibleSessionIDs.firstIndex(of: $0) }
  }
}

struct SidebarView: View {
  let store: HarnessMonitorStore
  let controls: HarnessMonitorStore.SessionControlsSlice
  let projection: HarnessMonitorStore.SessionProjectionSlice
  let sidebarUI: HarnessMonitorStore.SidebarUISlice
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
  @State private var sidebarWidth: CGFloat = 260
  @State private var sidebarVisibilityPhase = 1.0
  @State private var selectionRepairToken = 0
  private static let filterToolbarFadeHiddenWidth: CGFloat = 96
  private static let filterToolbarFadeVisibleWidth: CGFloat = 220

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

  private var usesFlatSearchResults: Bool {
    !controls.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

  private var selectionAnchor: SidebarSelectionAnchor {
    SidebarSelectionAnchor(
      selectedSessionID: sidebarUI.selectedSessionID,
      visibleSessionIDs: store.visibleSessionIDs
    )
  }

  // The sidebar search field already moves with the split view. Keep the
  // filter menu in that same toolbar lane and drive it from both the live
  // width and the split-view visibility state so it follows the motion but
  // still clears reliably once the sidebar finishes collapsing.
  private var filterToolbarVisibilityProgress: Double {
    let hiddenWidth = Self.filterToolbarFadeHiddenWidth
    let visibleWidth = Self.filterToolbarFadeVisibleWidth
    let widthProgress = Double(
      max(0, min(1, (sidebarWidth - hiddenWidth) / (visibleWidth - hiddenWidth))))
    return min(widthProgress, sidebarVisibilityPhase)
  }

  var body: some View {
    List(selection: sidebarSelection) {
      sidebarContent
    }
    .id(selectionRepairToken)
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
      if filterToolbarVisibilityProgress > 0.02 {
        ToolbarItem(placement: .primaryAction) {
          SidebarToolbarFilterMenu(
            store: store,
            sessionFilter: controls.sessionFilter,
            sessionFocusFilter: controls.sessionFocusFilter,
            sessionSortOrder: controls.sessionSortOrder,
            hasActiveFilters: hasActiveSidebarFilters
          )
          .opacity(filterToolbarVisibilityProgress)
          .scaleEffect(
            x: 0.94 + (0.06 * filterToolbarVisibilityProgress),
            y: 0.94 + (0.06 * filterToolbarVisibilityProgress),
            anchor: .trailing
          )
          .allowsHitTesting(filterToolbarVisibilityProgress > 0.85)
          .accessibilityHidden(filterToolbarVisibilityProgress < 0.15)
          .animation(.easeInOut(duration: 0.12), value: filterToolbarVisibilityProgress)
        }
      }
    }
    .onSubmit(of: .search) {
      if sidebarUI.isPersistenceAvailable {
        _ = store.recordSearch(controls.searchText)
      }
    }
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      updateSidebarWidth(width)
    }
    .onChange(of: selectionAnchor) { oldValue, newValue in
      repairSidebarListSelection(from: oldValue, to: newValue)
    }
    .onAppear(perform: hydrateCollapsedStateIfNeeded)
    .onChange(of: sidebarVisible, initial: true) { _, isVisible in
      withAnimation(.easeInOut(duration: 0.18)) {
        sidebarVisibilityPhase = isVisible ? 1 : 0
      }
    }
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
      if usesFlatSearchResults {
        flatSearchResults
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarSessionList)
          .accessibilityFrameMarker(HarnessMonitorAccessibility.sidebarSessionListContent)
      } else if let firstGroup = projection.groupedSessions.first {
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

  @ViewBuilder private var flatSearchResults: some View {
    ForEach(projection.visibleSessions, id: \.sessionId) { session in
      sessionRow(session)
    }
  }

  @ViewBuilder private var sidebarHeader: some View {
    if !recentSearchQueries.isEmpty {
      sidebarRecentSearches
        .padding(.horizontal, HarnessMonitorTheme.sectionSpacing)
        .padding(.top, HarnessMonitorTheme.spacingXL)
        .padding(.bottom, HarnessMonitorTheme.sectionSpacing)
    }
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

  func updateSidebarWidth(_ width: CGFloat) {
    guard abs(width - sidebarWidth) >= 0.5 else {
      return
    }
    sidebarWidth = max(width, 0)
  }

  private func repairSidebarListSelection(
    from previousAnchor: SidebarSelectionAnchor,
    to currentAnchor: SidebarSelectionAnchor
  ) {
    let selectionMovedWithinVisibleRows =
      previousAnchor.sessionID != nil
      && previousAnchor.sessionID == currentAnchor.sessionID
      && previousAnchor.visibleIndex != currentAnchor.visibleIndex
    let selectionWasCleared =
      previousAnchor.sessionID != nil
      && currentAnchor.sessionID == nil

    guard selectionMovedWithinVisibleRows || selectionWasCleared else {
      return
    }

    // macOS's native sidebar list can cling to the old row position when
    // reconnects insert or remove sessions around the active selection.
    // Rebuilding the list only for that anchor change keeps the highlight
    // aligned with the selection binding without resetting every live update.
    selectionRepairToken &+= 1
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
