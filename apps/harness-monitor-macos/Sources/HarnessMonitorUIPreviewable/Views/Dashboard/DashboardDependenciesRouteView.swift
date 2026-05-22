import HarnessMonitorKit
import SwiftUI

@MainActor
struct DashboardDependenciesRouteView: View {
  let store: HarnessMonitorStore
  @Binding var selectedRoute: DashboardWindowRoute
  let searchAutomationCommand: AppSearchAutomationCommand?

  @Environment(\.openSettingsSection)
  var openSettingsSection
  @Environment(\.openURL)
  var openURL

  @AppStorage(DashboardDependenciesPreferences.storageKey)
  var storedPreferences = ""
  @SceneStorage("dashboard.dependencies.filter")
  var filterModeRaw = DashboardDependenciesFilterMode.all.rawValue
  @SceneStorage("dashboard.dependencies.sort")
  var sortModeRaw = DashboardDependenciesSortMode.status.rawValue
  @SceneStorage("dashboard.dependencies.group")
  var groupModeRaw = DashboardDependenciesGroupMode.repository.rawValue
  @SceneStorage("dashboard.dependencies.search")
  var searchText = ""
  @SceneStorage("dashboard.dependencies.primary-selection")
  var persistedPrimarySelectionID = ""
  @SceneStorage("dashboard.dependencies.collapsed-repositories")
  var collapsedRepositoriesStorage = ""
  @SceneStorage("dashboard.dependencies.content-detail-width")
  var contentDetailWidth = SessionContentDetailSplitLayout.defaultContentWidth

  @State private var response = DependencyUpdatesQueryResponse(
    fetchedAt: "",
    fromCache: false,
    summary: DependencyUpdatesSummary(
      total: 0,
      reviewRequired: 0,
      readyToMerge: 0,
      autoApprovable: 0,
      waitingOnChecks: 0,
      blocked: 0
    ),
    items: []
  )
  @State private var isLoading = false
  @State private var isBackgroundRefreshing = false
  @State private var errorMessage: String?
  @State private var selectedIDs = Set<String>()
  @State private var isLabelSheetPresented = false
  @State private var labelDraft = ""
  @State private var labelTargetItems = [DependencyUpdateItem]()
  @State private var resolvedPreferences: DashboardDependenciesResolvedPreferences
  @State private var presentationWorker = DashboardDependenciesPresentationWorker()
  @State private var cachedPresentation = DashboardDependenciesPresentation.empty
  @State private var presentationGeneration: UInt64 = 0
  @State private var refreshTracker = DependencyRefreshTracker()
  @State private var inFlightTasks: [Task<Void, Never>] = []
  @State private var scheduler = DashboardDependenciesScheduler()
  @State private var collapsedRepositories = DashboardDependenciesCollapsedRepositories()
  @State private var labelMenuDataByRepository: [String: DashboardDependenciesRepoLabelMenuData] =
    [:]
  @State private var recentDependencyActions: [String: DashboardDependencyActivityEntry] = [:]

  init(
    store: HarnessMonitorStore,
    selectedRoute: Binding<DashboardWindowRoute>,
    searchAutomationCommand: AppSearchAutomationCommand? = nil
  ) {
    self.store = store
    _selectedRoute = selectedRoute
    self.searchAutomationCommand = searchAutomationCommand
    _resolvedPreferences = State(
      initialValue: DashboardDependenciesResolvedPreferences(
        storedValue: UserDefaults.standard.string(
          forKey: DashboardDependenciesPreferences.storageKey
        ) ?? ""
      )
    )
  }

  var routeResponse: DependencyUpdatesQueryResponse {
    get { response }
    nonmutating set { response = newValue }
  }

  var routeErrorMessage: String? {
    get { errorMessage }
    nonmutating set { errorMessage = newValue }
  }

  var routeIsLoading: Bool {
    get { isLoading }
    nonmutating set { isLoading = newValue }
  }

  var routeIsBackgroundRefreshing: Bool {
    get { isBackgroundRefreshing }
    nonmutating set { isBackgroundRefreshing = newValue }
  }

  var routeSelectedIDs: Set<String> {
    get { selectedIDs }
    nonmutating set { selectedIDs = newValue }
  }

  var routeSelectedIDsBinding: Binding<Set<String>> {
    Binding(
      get: { selectedIDs },
      set: { selectedIDs = $0 }
    )
  }

  var routeIsLabelSheetPresented: Bool {
    get { isLabelSheetPresented }
    nonmutating set { isLabelSheetPresented = newValue }
  }

  var routeLabelDraft: String {
    get { labelDraft }
    nonmutating set { labelDraft = newValue }
  }

  var routeLabelDraftBinding: Binding<String> {
    $labelDraft
  }

  var routeLabelTargetItems: [DependencyUpdateItem] {
    get { labelTargetItems }
    nonmutating set { labelTargetItems = newValue }
  }

  var routeResolvedPreferences: DashboardDependenciesResolvedPreferences {
    get { resolvedPreferences }
    nonmutating set { resolvedPreferences = newValue }
  }

  var routeRefreshTracker: DependencyRefreshTracker {
    get { refreshTracker }
    nonmutating set { refreshTracker = newValue }
  }

  var routeInFlightTasks: [Task<Void, Never>] {
    get { inFlightTasks }
    nonmutating set { inFlightTasks = newValue }
  }

  var routeScheduler: DashboardDependenciesScheduler {
    scheduler
  }

  var routeCollapsedRepositories: DashboardDependenciesCollapsedRepositories {
    get { collapsedRepositories }
    nonmutating set { collapsedRepositories = newValue }
  }

  var routeCollapsedRepositoriesStorage: String {
    get { collapsedRepositoriesStorage }
    nonmutating set { collapsedRepositoriesStorage = newValue }
  }

  var routeLabelMenuDataByRepository: [String: DashboardDependenciesRepoLabelMenuData] {
    get { labelMenuDataByRepository }
    nonmutating set { labelMenuDataByRepository = newValue }
  }

  var routeRecentDependencyActions: [String: DashboardDependencyActivityEntry] {
    get { recentDependencyActions }
    nonmutating set { recentDependencyActions = newValue }
  }

  var routePresentationWorker: DashboardDependenciesPresentationWorker {
    presentationWorker
  }

  var routeCachedPresentation: DashboardDependenciesPresentation {
    get { cachedPresentation }
    nonmutating set { cachedPresentation = newValue }
  }

  var routePresentationGeneration: UInt64 {
    get { presentationGeneration }
    nonmutating set { presentationGeneration = newValue }
  }

  var reloadTaskKey: DashboardDependenciesReloadTaskKey {
    DashboardDependenciesReloadTaskKey(
      preferencesSignature: resolvedPreferences.cacheHash,
      connectionState: store.connectionState
    )
  }

  var normalizedPreferences: DashboardDependenciesPreferences {
    resolvedPreferences.preferences
  }

  var groupMode: DashboardDependenciesGroupMode {
    DashboardDependenciesGroupMode(rawValue: groupModeRaw) ?? .repository
  }

  var presentationInput: DashboardDependenciesPresentationInput {
    let preferences = resolvedPreferences
    return DashboardDependenciesPresentationInput(
      items: response.items,
      filterModeRaw: filterModeRaw,
      sortModeRaw: sortModeRaw,
      searchText: "",
      configuredRepositories: preferences.repositories,
      configuredOrganizations: preferences.organizations,
      selectedIDs: selectedIDs,
      persistedPrimarySelectionID: persistedPrimarySelectionID
    )
  }

  var filteredItems: [DependencyUpdateItem] {
    cachedPresentation.filteredItems
  }

  var groupedItems: [DashboardDependenciesRepositoryGroup] {
    cachedPresentation.groupedItems
  }

  var selectedItems: [DependencyUpdateItem] {
    cachedPresentation.selectedItems
  }

  var primaryDetailItem: DependencyUpdateItem? {
    cachedPresentation.primaryDetailItem
  }

  var relativeUpdatedLabels: [String: String] {
    cachedPresentation.relativeUpdatedLabels
  }

  var body: some View {
    SessionContentDetailSplitView(
      contentWidth: $contentDetailWidth,
      commitContentWidth: { contentDetailWidth = $0 },
      dividerAccessibilityIdentifier:
        HarnessMonitorAccessibility.dashboardDependenciesDetailDivider,
      content: { contentPane },
      detail: { detailPane }
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDependenciesRoot)
    .task(id: reloadTaskKey) {
      await reload(forceRefresh: false)
    }
    .task(id: presentationInput) {
      await rebuildPresentation(input: presentationInput)
    }
    .sheet(isPresented: $isLabelSheetPresented) {
      labelSheet
    }
    .onChange(of: selectedIDs) { oldValue, newValue in
      persistedPrimarySelectionID = newValue.min() ?? persistedPrimarySelectionID
      prefetchSelectedBodies(adding: newValue.subtracting(oldValue))
    }
    .onChange(of: storedPreferences, initial: true) { _, newValue in
      syncPreferencesFromStorage(newValue)
    }
    .onChange(of: collapsedRepositoriesStorage, initial: true) { _, newValue in
      syncCollapsedRepositoriesFromStorage(newValue)
    }
    .onChange(of: response.repositoryLabels, initial: true) { _, _ in
      refreshLabelMenuData()
    }
    .onChange(of: normalizedPreferences.frequentLabelsCount) { _, _ in
      refreshLabelMenuData()
    }
    .onChange(of: selectedRoute) { _, newValue in
      if newValue != .dependencies { cancelAllInFlightTasks() }
    }
    .dashboardDependenciesOnSystemWake(perform: handleSystemWake)
    .dashboardDependenciesToolbarSearch(
      query: $searchText,
      items: response.items,
      automationCommand: searchAutomationCommand
    ) { pullRequestID in
      selectedIDs = [pullRequestID]
    }
  }
}
