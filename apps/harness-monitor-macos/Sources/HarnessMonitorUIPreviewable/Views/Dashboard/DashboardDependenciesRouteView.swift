import HarnessMonitorKit
import SwiftUI

@MainActor let dependenciesRelativeFormatter: RelativeDateTimeFormatter = {
  let formatter = RelativeDateTimeFormatter()
  formatter.unitsStyle = .short
  return formatter
}()

enum DashboardDependenciesRemoteLoader {
  static func query(
    client: any HarnessMonitorDependenciesClientProtocol,
    request: DependencyUpdatesQueryRequest
  ) async throws -> DependencyUpdatesQueryResponse {
    let task = Task.detached(priority: .userInitiated) {
      try await client.queryDependencyUpdates(request: request)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  static func refresh(
    client: any HarnessMonitorDependenciesClientProtocol,
    request: DependencyUpdatesRefreshRequest
  ) async throws -> DependencyUpdatesRefreshResponse {
    let task = Task.detached(priority: .userInitiated) {
      try await client.refreshDependencyUpdates(request: request)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}

struct DashboardDependenciesReloadTaskKey: Equatable {
  let preferencesSignature: String
  let connectionState: HarnessMonitorStore.ConnectionState
}

struct DashboardDependenciesQueryRequestParts {
  let authors: [String]
  let organizations: [String]
  let repositories: [String]
  let excludeRepositories: [String]
  let cacheMaxAgeSeconds: UInt64
  let forceRefresh: Bool
}

struct DashboardDependenciesResolvedPreferences: Equatable {
  let preferences: DashboardDependenciesPreferences
  let authors: [String]
  let organizations: [String]
  let repositories: [String]
  let excludeRepositories: [String]
  let cacheHash: String

  init(storedValue: String) {
    self.init(preferences: DashboardDependenciesPreferences.decode(from: storedValue))
  }

  init(preferences: DashboardDependenciesPreferences) {
    let normalized = preferences.normalized()
    self.preferences = normalized
    authors = normalized.normalizedAuthors
    organizations = normalized.normalizedOrganizations
    repositories = normalized.normalizedRepositories
    excludeRepositories = normalized.normalizedExcludeRepositories
    cacheHash = DependencyUpdatesCache.preferencesHash(
      for: Self.queryRequest(
        DashboardDependenciesQueryRequestParts(
          authors: authors,
          organizations: organizations,
          repositories: repositories,
          excludeRepositories: excludeRepositories,
          cacheMaxAgeSeconds: normalized.cacheMaxAgeSeconds,
          forceRefresh: false
        )
      )
    )
  }

  func queryRequest(forceRefresh: Bool) -> DependencyUpdatesQueryRequest {
    Self.queryRequest(
      DashboardDependenciesQueryRequestParts(
        authors: authors,
        organizations: organizations,
        repositories: repositories,
        excludeRepositories: excludeRepositories,
        cacheMaxAgeSeconds: preferences.cacheMaxAgeSeconds,
        forceRefresh: forceRefresh
      )
    )
  }

  func perRepositoryQueryRequest(
    for repository: String,
    forceRefresh: Bool
  ) -> DependencyUpdatesQueryRequest {
    Self.queryRequest(
      DashboardDependenciesQueryRequestParts(
        authors: authors,
        organizations: [],
        repositories: [repository],
        excludeRepositories: excludeRepositories,
        cacheMaxAgeSeconds: preferences.cacheMaxAgeSeconds,
        forceRefresh: forceRefresh
      )
    )
  }

  fileprivate static func queryRequest(_ parts: DashboardDependenciesQueryRequestParts)
    -> DependencyUpdatesQueryRequest
  {
    DependencyUpdatesQueryRequest(
      authors: parts.authors,
      organizations: parts.organizations,
      repositories: parts.repositories,
      excludeRepositories: parts.excludeRepositories,
      forceRefresh: parts.forceRefresh,
      cacheMaxAgeSeconds: max(
        parts.cacheMaxAgeSeconds,
        DashboardDependenciesPreferences.minimumPerRepositoryIntervalSeconds
      )
    )
  }
}

enum DashboardDependenciesMissingClientState: Equatable {
  case ignore
  case loading
  case error(String)
}

func dashboardDependenciesMissingClientState(
  backgroundRefresh: Bool,
  connectionState: HarnessMonitorStore.ConnectionState
) -> DashboardDependenciesMissingClientState {
  guard !backgroundRefresh else {
    return .ignore
  }
  if connectionState == .connecting {
    return .loading
  }
  return .error("The dependencies route needs a daemon client")
}

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

  @State var response = DependencyUpdatesQueryResponse(
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
  @State var isLoading = false
  @State var isBackgroundRefreshing = false
  @State var errorMessage: String?
  @State var selectedIDs = Set<String>()
  @State var isLabelSheetPresented = false
  @State var labelDraft = ""
  @State var labelTargetItems = [DependencyUpdateItem]()
  @State var inFlightActionTitle: String?
  @State var resolvedPreferences: DashboardDependenciesResolvedPreferences
  @State var presentationWorker = DashboardDependenciesPresentationWorker()
  @State var cachedPresentation = DashboardDependenciesPresentation.empty
  @State var presentationGeneration: UInt64 = 0
  @State var refreshingPullRequestIDs = Set<String>()
  @State var scheduler = DashboardDependenciesScheduler()
  @State var collapsedRepositories = DashboardDependenciesCollapsedRepositories()
  @State var labelMenuDataByRepository: [String: DashboardDependenciesRepoLabelMenuData] =
    [:]

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

  var routeResolvedPreferences: DashboardDependenciesResolvedPreferences {
    resolvedPreferences
  }

  var routeRefreshingPullRequestIDs: Set<String> {
    get { refreshingPullRequestIDs }
    nonmutating set { refreshingPullRequestIDs = newValue }
  }

  var routeScheduler: DashboardDependenciesScheduler {
    scheduler
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
    .onChange(of: selectedIDs) { _, newValue in
      persistedPrimarySelectionID = newValue.min() ?? persistedPrimarySelectionID
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
    .dashboardDependenciesToolbarSearch(
      query: $searchText,
      items: response.items,
      automationCommand: searchAutomationCommand
    ) { pullRequestID in
      selectedIDs = [pullRequestID]
    }
  }

  func refreshLabelMenuData() {
    let limit = normalizedPreferences.frequentLabelsCount
    let usageCache = repositoryLabelUsageCache
    var result: [String: DashboardDependenciesRepoLabelMenuData] = [:]
    result.reserveCapacity(response.repositoryLabels.count)
    for (repository, labels) in response.repositoryLabels {
      let sorted = labels.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
      let frequent = usageCache?.topUsed(repositories: [repository], limit: limit) ?? []
      result[repository] = DashboardDependenciesRepoLabelMenuData(
        sortedLabels: sorted,
        frequentNames: frequent
      )
    }
    guard result != labelMenuDataByRepository else { return }
    labelMenuDataByRepository = result
  }

  func rowAvailableLabels(for item: DependencyUpdateItem) -> [DependencyUpdateRepositoryLabel] {
    guard let data = labelMenuDataByRepository[item.repository] else { return [] }
    let applied = Set(item.labels)
    return data.sortedLabels.filter { !applied.contains($0.name) }
  }

  func rowFrequentLabelNames(for item: DependencyUpdateItem) -> [String] {
    labelMenuDataByRepository[item.repository]?.frequentNames ?? []
  }

  func syncCollapsedRepositoriesFromStorage(_ storedValue: String) {
    let next = DashboardDependenciesCollapsedRepositories.decode(from: storedValue)
    guard next != collapsedRepositories else { return }
    collapsedRepositories = next
  }

  func syncPreferencesFromStorage(_ storedValue: String) {
    let nextPreferences = DashboardDependenciesResolvedPreferences(storedValue: storedValue)
    guard nextPreferences != resolvedPreferences else { return }
    resolvedPreferences = nextPreferences
  }

  var contentPane: some View {
    VStack(alignment: .leading, spacing: 14) {
      filterBar
      contentListPane
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(20)
  }

  @ViewBuilder var contentListPane: some View {
    if let errorMessage, !isLoading {
      errorState(message: errorMessage)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else {
      dependenciesList
    }
  }

  var filterBar: some View {
    filterControls
  }

  var filterControls: some View {
    DashboardDependenciesControlStrip(
      filterModeRaw: $filterModeRaw,
      sortModeRaw: $sortModeRaw,
      groupModeRaw: $groupModeRaw,
      onRefresh: {
        Task { await reload(forceRefresh: true) }
      },
      onClearCache: {
        Task { await clearCacheAndReload() }
      }
    )
  }

  var dependenciesList: some View {
    List(selection: $selectedIDs) {
      if filteredItems.isEmpty, !isLoading {
        ContentUnavailableView {
          Label("No dependency updates", systemImage: "shippingbox")
        } description: {
          Text("Adjust your filters or configure a broader source scope")
        }
        .frame(maxWidth: .infinity, minHeight: 280)
      } else if groupMode == .repository {
        ForEach(groupedItems, id: \.repository) { group in
          Section {
            if !collapsedRepositories.contains(group.repository) {
              ForEach(group.items) { item in
                dependencyRow(item, showsRepository: false)
              }
            }
          } header: {
            repositorySectionHeader(group.repository, itemCount: group.items.count)
          }
        }
      } else {
        ForEach(filteredItems) { item in
          dependencyRow(item, showsRepository: true)
        }
      }
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDependenciesList)
    .contextMenu(forSelectionType: String.self) { selection in
      dependencySelectionContextMenu(for: selection)
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .overlay {
      if isLoading {
        ProgressView("Loading dependencies…")
          .controlSize(.large)
      }
    }
  }

  var detailPane: some View {
    Group {
      if let errorMessage, !isLoading {
        errorState(message: errorMessage)
      } else if selectedItems.count > 1 {
        batchDetail
      } else if let item = primaryDetailItem {
        DashboardDependencyDetailView(item: item, store: store) {
          dependencyActionBar(items: [item])
        }
      } else if isLoading {
        ProgressView("Loading dependencies…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ContentUnavailableView {
          Label("Select a dependency update", systemImage: "sidebar.right")
        } description: {
          Text("Review checks, approvals, labels, and native actions without leaving the dashboard")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDependenciesDetail)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  var batchDetail: some View {
    HarnessMonitorColumnScrollView(
      horizontalPadding: 24,
      verticalPadding: 24,
      constrainContentWidth: true,
      readableWidth: false,
      topScrollEdgeEffect: .soft,
      scrollSurfaceIdentifier: HarnessMonitorAccessibility.dashboardDependenciesDetail,
      scrollSurfaceLabel: "Dependencies detail"
    ) {
      VStack(alignment: .leading, spacing: 24) {
        DashboardDependencyDetailCard(
          title: "\(selectedItems.count) selected",
          subtitle: "Run batch dependency actions across the current selection"
        ) {
          dependencyActionBar(items: selectedItems)
        }
      }
      .frame(maxWidth: dependenciesDetailMaxWidth, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
    }
  }

  func dependencyRow(
    _ item: DependencyUpdateItem,
    showsRepository: Bool
  ) -> some View {
    DashboardDependencyRow(
      item: item,
      showsRepository: showsRepository,
      isRefreshing: refreshingPullRequestIDs.contains(item.pullRequestID),
      updatedLabel: relativeUpdatedLabel(for: item)
    )
  }

  @ViewBuilder
  func dependencySelectionContextMenu(for selection: Set<String>) -> some View {
    let items = contextMenuItems(forSelection: selection)
    if let primaryItem = items.first {
      let isSingleItem = items.count == 1
      let availableLabels = contextMenuAvailableLabels(for: items)
      let frequentNames = contextMenuFrequentNames(for: items)
      if isSingleItem {
        Button("Open Pull Request") {
          openItem(primaryItem)
        }
        Button("Copy Link") {
          HarnessMonitorClipboard.copy(primaryItem.url)
        }
        Divider()
      }
      Button("Approve") {
        Task { await approve(items: items) }
      }
      .disabled(!items.contains { $0.canAttemptManualApproval })
      Button("Merge") {
        Task { await merge(items: items) }
      }
      .disabled(!items.contains { $0.canAttemptManualMerge })
      Button("Rerun Checks") {
        Task { await rerunChecks(items: items) }
      }
      .disabled(!items.contains { $0.hasRerunnableChecks })
      DashboardDependenciesLabelPickerMenu(
        title: "Add Label",
        labels: availableLabels,
        frequentNames: frequentNames,
        showsDescriptions: normalizedPreferences.showLabelDescriptions,
        onSelect: { name in Task { await addLabel(name, to: items) } },
        onCustom: {
          labelTargetItems = items
          labelDraft = ""
          isLabelSheetPresented = true
        }
      )
      Button("Auto") {
        Task { await auto(items: items) }
      }
      .disabled(!items.contains { $0.canRunAutoMode })
      if isSingleItem, primaryItem.canStartFixCI {
        Button("Fix CI") {
          Task { await fixCI(item: primaryItem) }
        }
      }
    }
  }

  func contextMenuItems(forSelection selection: Set<String>) -> [DependencyUpdateItem] {
    guard !selection.isEmpty else { return [] }
    return filteredItems.filter { selection.contains($0.pullRequestID) }
  }

  func contextMenuAvailableLabels(
    for items: [DependencyUpdateItem]
  ) -> [DependencyUpdateRepositoryLabel] {
    if items.count == 1, let item = items.first {
      return rowAvailableLabels(for: item)
    }
    return dashboardDependenciesAvailableLabels(
      repositoryLabels: response.repositoryLabels,
      items: items
    )
  }

  func contextMenuFrequentNames(for items: [DependencyUpdateItem]) -> [String] {
    if items.count == 1, let item = items.first {
      return rowFrequentLabelNames(for: item)
    }
    return frequentLabelNames(for: items)
  }

  func repositorySectionHeader(_ repository: String, itemCount: Int) -> some View {
    DashboardDependenciesRepositorySectionHeader(
      repository: repository,
      itemCount: itemCount,
      isCollapsed: collapsedRepositories.contains(repository),
      scheduler: scheduler,
      onToggleCollapse: { toggleRepositoryCollapse(repository) }
    )
  }

  func dependencyActionBar(items: [DependencyUpdateItem]) -> some View {
    DashboardDependencyActionBar(
      items: items,
      availableLabels: dashboardDependenciesAvailableLabels(
        repositoryLabels: response.repositoryLabels,
        items: items
      ),
      frequentNames: frequentLabelNames(for: items),
      showsDescriptions: normalizedPreferences.showLabelDescriptions,
      onApprove: { Task { await approve(items: items) } },
      onMerge: { Task { await merge(items: items) } },
      onRerunChecks: { Task { await rerunChecks(items: items) } },
      onSelectLabel: { name in Task { await addLabel(name, to: items) } },
      onCustomLabel: {
        labelTargetItems = items
        labelDraft = ""
        isLabelSheetPresented = true
      },
      onCopyApprovalLinks: { copyApprovalLinks(for: items) },
      onAuto: {
        if items.count == 1, let item = items.first {
          Task { await auto(items: [item]) }
        } else {
          Task { await auto(items: items) }
        }
      },
      onOpenItem: {
        if let item = items.first {
          openItem(item)
        }
      },
      onFixCI: {
        if let item = items.first {
          Task { await fixCI(item: item) }
        }
      }
    )
  }

  var labelSheet: some View {
    DashboardDependenciesCustomLabelSheet(
      items: labelTargetItems,
      suggestions: dashboardDependenciesAvailableLabels(
        repositoryLabels: response.repositoryLabels,
        items: labelTargetItems
      ),
      draft: $labelDraft,
      onApply: { label in
        isLabelSheetPresented = false
        let items = labelTargetItems
        labelTargetItems = []
        Task { await addLabel(label, to: items) }
      },
      onCancel: {
        labelTargetItems = []
        isLabelSheetPresented = false
      }
    )
  }
}

extension DashboardDependenciesRouteView {
  func reload(forceRefresh: Bool, backgroundRefresh: Bool = false) async {
    hydrateDependenciesFromCacheIfNeeded()
    guard store.apiClient != nil else {
      switch dashboardDependenciesMissingClientState(
        backgroundRefresh: backgroundRefresh,
        connectionState: store.connectionState
      ) {
      case .ignore:
        return
      case .loading:
        isLoading = true
        errorMessage = nil
        return
      case .error(let message):
        isLoading = false
        errorMessage = message
        return
      }
    }
    if backgroundRefresh {
      isBackgroundRefreshing = true
    } else {
      isLoading = true
      errorMessage = nil
    }
    defer {
      if backgroundRefresh {
        isBackgroundRefreshing = false
      } else {
        isLoading = false
      }
    }
    await startScheduler(forceRefreshAll: forceRefresh)
  }

  func clearCacheAndReload() async {
    guard let client = store.apiClient else { return }
    do {
      let cleared = try await client.clearDependencyUpdatesCache()
      store.presentSuccessFeedback(
        "Cleared \(cleared.clearedEntries) cached dependency query bucket(s)"
      )
      await reload(forceRefresh: true)
    } catch {
      store.presentFailureFeedback(error.localizedDescription)
    }
  }

  func approve(items: [DependencyUpdateItem]) async {
    await performMutation("Approving", items: items) { client in
      try await client.approveDependencyUpdates(
        request: DependencyUpdatesApproveRequest(targets: items.map(\.target))
      )
    }
  }

  func merge(items: [DependencyUpdateItem]) async {
    let nextID = nextSelectionID(after: items)
    await performMutation(
      "Merging",
      items: items,
      onSuccess: {
        if let nextID {
          selectedIDs = [nextID]
        }
      },
      operation: { client in
        try await client.mergeDependencyUpdates(
          request: DependencyUpdatesMergeRequest(
            targets: items.map(\.target),
            method: normalizedPreferences.mergeMethod
          )
        )
      }
    )
  }

  func nextSelectionID(after items: [DependencyUpdateItem]) -> String? {
    let mergedIDs = Set(items.map(\.pullRequestID))
    let list = filteredItems
    guard
      let lastMergedIndex = list.lastIndex(where: { mergedIDs.contains($0.pullRequestID) })
    else {
      return nil
    }
    return list[(lastMergedIndex + 1)...]
      .first(where: { !mergedIDs.contains($0.pullRequestID) })?
      .pullRequestID
  }

  func rerunChecks(items: [DependencyUpdateItem]) async {
    await performMutation("Rerunning", items: items) { client in
      try await client.rerunDependencyUpdateChecks(
        request: DependencyUpdatesRerunChecksRequest(targets: items.map(\.rerunTarget))
      )
    }
  }

  func addLabel(_ label: String, to items: [DependencyUpdateItem]) async {
    await performMutation(
      "Labeling",
      items: items,
      onSuccess: { recordLabelUsage(label, items: items) },
      operation: { client in
        try await client.addDependencyUpdateLabel(
          request: DependencyUpdatesLabelRequest(targets: items.map(\.target), label: label)
        )
      }
    )
  }

  func auto(items: [DependencyUpdateItem]) async {
    await performMutation("Running auto mode", items: items) { client in
      try await client.autoDependencyUpdates(
        request: DependencyUpdatesAutoRequest(
          targets: items.map(\.target),
          method: normalizedPreferences.mergeMethod
        )
      )
    }
  }

  func fixCI(item: DependencyUpdateItem) async {
    guard let client = store.apiClient else { return }
    inFlightActionTitle = "Creating Fix CI work…"
    do {
      _ = try await client.createTaskBoardItem(
        request: TaskBoardCreateItemRequest(
          title: "Fix CI · \(item.repository)#\(item.number)",
          body: """
            Investigate and restore mergeability for \(item.repository)#\(item.number).

            Pull request: \(item.url)
            Review status: \(item.reviewStatus.label)
            Check status: \(item.checkStatus.label)
            """,
          priority: item.requiresAttention ? .high : .medium,
          agentMode: .headless,
          tags: ["dependencies", "fix-ci"],
          externalRefs: [
            TaskBoardExternalRef(
              provider: .gitHub,
              externalId: "\(item.repository)#\(item.number)",
              url: item.url
            )
          ],
          planning: TaskBoardPlanningState(
            summary: "Repair dependency-update CI failures and restore mergeability"
          )
        )
      )
      selectedRoute = .taskBoard
    } catch {
      store.presentFailureFeedback(error.localizedDescription)
    }
    inFlightActionTitle = nil
  }

  func performMutation(
    _ title: String,
    items: [DependencyUpdateItem],
    onSuccess: @MainActor () -> Void = {},
    operation:
      @escaping (any HarnessMonitorClientProtocol) async throws
      -> DependencyUpdatesActionResponse
  ) async {
    guard let client = store.apiClient else { return }
    inFlightActionTitle = title
    defer { inFlightActionTitle = nil }
    do {
      let response = try await operation(client)
      store.presentSuccessFeedback(response.summary)
      onSuccess()
      scheduleAffectedRefresh(for: items, using: client)
    } catch {
      store.presentFailureFeedback(error.localizedDescription)
    }
  }

  func openItem(_ item: DependencyUpdateItem) {
    guard let url = URL(string: item.url) else { return }
    openURL(url)
  }

  func copyApprovalLinks(for items: [DependencyUpdateItem]) {
    let scopedItems: [DependencyUpdateItem]
    if selectedItems.isEmpty, items.count == 1, let repository = items.first?.repository,
      groupMode == .repository
    {
      scopedItems = filteredItems.filter { $0.repository == repository }
    } else {
      scopedItems = items
    }
    let links =
      scopedItems
      .filter { $0.reviewStatus == .reviewRequired }
      .map(\.url)
    guard !links.isEmpty else {
      store.toast.presentWarning("No approval links are needed for the current scope")
      return
    }
    HarnessMonitorClipboard.copy(links.joined(separator: "\n"))
    store.presentSuccessFeedback("Copied \(links.count) approval link(s)")
  }

  func relativeUpdatedLabel(for item: DependencyUpdateItem) -> String {
    relativeUpdatedLabels[item.pullRequestID] ?? item.updatedAt
  }

  func toggleRepositoryCollapse(_ repository: String) {
    var collapsed = collapsedRepositories
    collapsed.toggle(repository)
    collapsedRepositories = collapsed
    collapsedRepositoriesStorage = collapsed.encodedString
  }

  func reconcileSelection() {
    let liveIDs = Set(response.items.map(\.pullRequestID))
    selectedIDs = selectedIDs.intersection(liveIDs)
    if selectedIDs.isEmpty, let persisted = persistedPrimarySelectionID.nonEmpty,
      liveIDs.contains(persisted)
    {
      selectedIDs = [persisted]
    }
  }

  @MainActor
  func rebuildPresentation(input: DashboardDependenciesPresentationInput) async {
    presentationGeneration &+= 1
    let generation = presentationGeneration
    let presentation = await presentationWorker.compute(input: input)
    guard !Task.isCancelled, presentationGeneration == generation else {
      return
    }
    if cachedPresentation != presentation {
      cachedPresentation = presentation
    }
  }
}
