// swiftlint:disable file_length
// swiftlint:disable type_body_length
import HarnessMonitorKit
import SwiftUI

@MainActor private let dependenciesRelativeFormatter: RelativeDateTimeFormatter = {
  let formatter = RelativeDateTimeFormatter()
  formatter.unitsStyle = .short
  return formatter
}()

private let dependenciesDetailMaxWidth: CGFloat = 940

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

private struct DashboardDependenciesQueryRequestParts {
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

  private static func queryRequest(_ parts: DashboardDependenciesQueryRequestParts)
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
  private var openSettingsSection
  @Environment(\.openURL)
  private var openURL

  @AppStorage(DashboardDependenciesPreferences.storageKey)
  private var storedPreferences = ""
  @SceneStorage("dashboard.dependencies.filter")
  private var filterModeRaw = DashboardDependenciesFilterMode.all.rawValue
  @SceneStorage("dashboard.dependencies.sort")
  private var sortModeRaw = DashboardDependenciesSortMode.status.rawValue
  @SceneStorage("dashboard.dependencies.group")
  private var groupModeRaw = DashboardDependenciesGroupMode.repository.rawValue
  @SceneStorage("dashboard.dependencies.search")
  private var searchText = ""
  @SceneStorage("dashboard.dependencies.primary-selection")
  private var persistedPrimarySelectionID = ""
  @SceneStorage("dashboard.dependencies.collapsed-repositories")
  private var collapsedRepositoriesStorage = ""
  @SceneStorage("dashboard.dependencies.content-detail-width")
  private var contentDetailWidth = SessionContentDetailSplitLayout.defaultContentWidth

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
  @State private var inFlightActionTitle: String?
  @State private var resolvedPreferences: DashboardDependenciesResolvedPreferences
  @State private var presentationWorker = DashboardDependenciesPresentationWorker()
  @State private var cachedPresentation = DashboardDependenciesPresentation.empty
  @State private var presentationGeneration: UInt64 = 0
  @State private var refreshingPullRequestIDs = Set<String>()
  @State private var scheduler = DashboardDependenciesScheduler()
  @State private var collapsedRepositories = DashboardDependenciesCollapsedRepositories()
  @State private var labelMenuDataByRepository: [String: DashboardDependenciesRepoLabelMenuData] =
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

  private var reloadTaskKey: DashboardDependenciesReloadTaskKey {
    DashboardDependenciesReloadTaskKey(
      preferencesSignature: resolvedPreferences.cacheHash,
      connectionState: store.connectionState
    )
  }

  var normalizedPreferences: DashboardDependenciesPreferences {
    resolvedPreferences.preferences
  }

  private var groupMode: DashboardDependenciesGroupMode {
    DashboardDependenciesGroupMode(rawValue: groupModeRaw) ?? .repository
  }

  private var presentationInput: DashboardDependenciesPresentationInput {
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

  private var filteredItems: [DependencyUpdateItem] {
    cachedPresentation.filteredItems
  }

  private var groupedItems: [DashboardDependenciesRepositoryGroup] {
    cachedPresentation.groupedItems
  }

  private var selectedItems: [DependencyUpdateItem] {
    cachedPresentation.selectedItems
  }

  private var primaryDetailItem: DependencyUpdateItem? {
    cachedPresentation.primaryDetailItem
  }

  private var relativeUpdatedLabels: [String: String] {
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

  private func syncCollapsedRepositoriesFromStorage(_ storedValue: String) {
    let next = DashboardDependenciesCollapsedRepositories.decode(from: storedValue)
    guard next != collapsedRepositories else { return }
    collapsedRepositories = next
  }

  private func syncPreferencesFromStorage(_ storedValue: String) {
    let nextPreferences = DashboardDependenciesResolvedPreferences(storedValue: storedValue)
    guard nextPreferences != resolvedPreferences else { return }
    resolvedPreferences = nextPreferences
  }

  private var contentPane: some View {
    VStack(alignment: .leading, spacing: 14) {
      filterBar
      contentListPane
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(20)
  }

  @ViewBuilder private var contentListPane: some View {
    if let errorMessage, !isLoading {
      errorState(message: errorMessage)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else {
      dependenciesList
    }
  }

  private var filterBar: some View {
    filterControls
  }

  private var filterControls: some View {
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

  private var dependenciesList: some View {
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

  private var detailPane: some View {
    Group {
      if let errorMessage, !isLoading {
        errorState(message: errorMessage)
      } else if selectedItems.count > 1 {
        batchDetail
      } else if let item = primaryDetailItem {
        dependencyDetail(item)
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

  private var batchDetail: some View {
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
        detailCard(
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

  private func dependencyDetail(_ item: DependencyUpdateItem) -> some View {
    HarnessMonitorColumnScrollView(
      horizontalPadding: 24,
      verticalPadding: 24,
      constrainContentWidth: true,
      readableWidth: false,
      topScrollEdgeEffect: .soft,
      scrollSurfaceIdentifier: HarnessMonitorAccessibility.dashboardDependenciesDetail,
      scrollSurfaceLabel: "Dependencies detail"
    ) {
      VStack(alignment: .leading, spacing: 18) {
        detailCard(
          title: item.title, subtitle: "\(item.repository)#\(item.number) · @\(item.authorLogin)"
        ) {
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
            dependencyActionBar(items: [item])
            DashboardDependencyStatusStrip(item: item)
          }
        }
        detailSection(nil) {
          descriptionView(for: item)
        }
        .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDependenciesDescription)
        detailSection("Checks") {
          DashboardDependencyCheckList(checks: item.checks)
        }
        detailSection("Reviews") {
          DashboardDependencyReviewList(reviews: item.reviews)
        }
        detailSection("Labels") {
          DashboardDependencyLabelStrip(labels: item.labels)
        }
      }
      .frame(maxWidth: dependenciesDetailMaxWidth, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
      .task(
        id: DependencyUpdateBodyTaskKey(
          item: item, isDaemonOnline: store.connectionState == .online)
      ) {
        await store.prepareDependencyUpdateBody(for: item)
      }
    }
  }

  private func descriptionView(for item: DependencyUpdateItem) -> some View {
    DashboardDependenciesDescriptionView(
      store: store,
      pullRequestID: item.pullRequestID
    )
  }

  private func dependencyRow(
    _ item: DependencyUpdateItem,
    showsRepository: Bool
  ) -> some View {
    DashboardDependencyListRow(
      item: item,
      showsRepository: showsRepository,
      isRefreshing: refreshingPullRequestIDs.contains(item.pullRequestID),
      updatedLabel: relativeUpdatedLabel(for: item)
    )
    .tag(item.pullRequestID)
    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    .listRowSeparator(.hidden)
    .contextMenu {
      Button("Open Pull Request") {
        openItem(item)
      }
      Button("Copy Link") {
        HarnessMonitorClipboard.copy(item.url)
      }
      Divider()
      Button("Approve") {
        Task { await approve(items: [item]) }
      }
      .disabled(!item.canAttemptManualApproval)
      Button("Merge") {
        Task { await merge(items: [item]) }
      }
      .disabled(!item.canAttemptManualMerge)
      Button("Rerun Checks") {
        Task { await rerunChecks(items: [item]) }
      }
      .disabled(!item.hasRerunnableChecks)
      DashboardDependenciesLabelPickerMenu(
        title: "Add Label",
        labels: rowAvailableLabels(for: item),
        frequentNames: rowFrequentLabelNames(for: item),
        showsDescriptions: normalizedPreferences.showLabelDescriptions,
        onSelect: { name in Task { await addLabel(name, to: [item]) } },
        onCustom: {
          labelTargetItems = [item]
          labelDraft = ""
          isLabelSheetPresented = true
        }
      )
      Button("Auto") {
        Task { await auto(items: [item]) }
      }
      .disabled(!item.canRunAutoMode)
      if item.canStartFixCI {
        Button("Fix CI") {
          Task { await fixCI(item: item) }
        }
      }
    }
  }

  private func repositorySectionHeader(_ repository: String, itemCount: Int) -> some View {
    DashboardDependenciesRepositorySectionHeader(
      repository: repository,
      itemCount: itemCount,
      isCollapsed: collapsedRepositories.contains(repository),
      scheduler: scheduler,
      onToggleCollapse: { toggleRepositoryCollapse(repository) }
    )
  }

  private func dependencyActionBar(items: [DependencyUpdateItem]) -> some View {
    HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.itemSpacing) {
      HarnessMonitorWrapLayout(
        spacing: HarnessMonitorTheme.itemSpacing,
        lineSpacing: HarnessMonitorTheme.itemSpacing
      ) {
        dependencyActionButtons(items: items)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func dependencyActionButtons(items: [DependencyUpdateItem]) -> some View {
    actionButton("Approve", systemImage: "checkmark.seal", prominence: .primary) {
      Task { await approve(items: items) }
    }
    .disabled(!items.contains { $0.canAttemptManualApproval })

    actionButton("Merge", systemImage: "arrow.triangle.merge", prominence: .success) {
      Task { await merge(items: items) }
    }
    .disabled(!items.contains { $0.canAttemptManualMerge })

    actionButton("Rerun Checks", systemImage: "arrow.clockwise.circle", prominence: .secondary) {
      Task { await rerunChecks(items: items) }
    }
    .disabled(!items.contains { $0.hasRerunnableChecks })

    DashboardDependenciesLabelPickerActionMenu(
      labels: dashboardDependenciesAvailableLabels(
        repositoryLabels: response.repositoryLabels,
        items: items
      ),
      frequentNames: frequentLabelNames(for: items),
      showsDescriptions: normalizedPreferences.showLabelDescriptions,
      onSelect: { name in Task { await addLabel(name, to: items) } },
      onCustom: {
        labelTargetItems = items
        labelDraft = ""
        isLabelSheetPresented = true
      }
    )
    .disabled(items.isEmpty)

    actionButton("Copy Approval Links", systemImage: "doc.on.doc", prominence: .secondary) {
      copyApprovalLinks(for: items)
    }

    if items.count == 1, let item = items.first {
      actionButton("Auto", systemImage: "bolt", prominence: .utility) {
        Task { await auto(items: [item]) }
      }
      .disabled(!item.canRunAutoMode)
      actionButton("Open Pull Request", systemImage: "safari", prominence: .utility) {
        openItem(item)
      }
      if item.canStartFixCI {
        actionButton("Fix CI", systemImage: "wrench.and.screwdriver", prominence: .secondary) {
          Task { await fixCI(item: item) }
        }
        .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDependenciesFixCIButton)
      }
    } else {
      actionButton("Auto", systemImage: "bolt", prominence: .utility) {
        Task { await auto(items: items) }
      }
      .disabled(!items.contains { $0.canRunAutoMode })
    }
  }

  private var labelSheet: some View {
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

  private func detailCard<Content: View>(
    title: String,
    subtitle: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      Text(title)
        .scaledFont(.system(.title2, design: .rounded, weight: .semibold))
        .foregroundStyle(HarnessMonitorTheme.ink)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
      Text(subtitle)
        .scaledFont(.callout.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      content()
    }
    .frame(maxWidth: dependenciesDetailMaxWidth, alignment: .leading)
    .padding(.bottom, HarnessMonitorTheme.spacingLG)
    .overlay(alignment: .bottom) {
      Divider().opacity(0.42)
    }
  }

  private func detailSection<Content: View>(_ title: String?, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      if let title {
        Text(title)
          .scaledFont(.headline.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.ink)
      }
      content()
    }
    .frame(maxWidth: dependenciesDetailMaxWidth, alignment: .leading)
    .padding(.vertical, HarnessMonitorTheme.spacingLG)
    .overlay(alignment: .top) {
      Divider().opacity(0.34)
    }
  }

  private func actionButton(
    _ title: String,
    systemImage: String,
    prominence: DashboardDependencyActionProminence = .utility,
    action: @escaping () -> Void
  )
    -> some View
  {
    DashboardDependencyActionButton(
      title: title,
      systemImage: systemImage,
      prominence: prominence,
      action: action
    )
  }

  private func errorState(message: String) -> some View {
    ContentUnavailableView {
      Label("Dependencies unavailable", systemImage: "exclamationmark.triangle")
    } description: {
      Text(message)
    } actions: {
      Button("Open Secrets") {
        openSettingsSection(.secrets)
      }
      Button("Open Sources Settings") {
        openSettingsSection(.repositories)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

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

  private func clearCacheAndReload() async {
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

  private func approve(items: [DependencyUpdateItem]) async {
    await performMutation("Approving", items: items) { client in
      try await client.approveDependencyUpdates(
        request: DependencyUpdatesApproveRequest(targets: items.map(\.target))
      )
    }
  }

  private func merge(items: [DependencyUpdateItem]) async {
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

  private func nextSelectionID(after items: [DependencyUpdateItem]) -> String? {
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

  private func rerunChecks(items: [DependencyUpdateItem]) async {
    await performMutation("Rerunning", items: items) { client in
      try await client.rerunDependencyUpdateChecks(
        request: DependencyUpdatesRerunChecksRequest(targets: items.map(\.rerunTarget))
      )
    }
  }

  private func addLabel(_ label: String, to items: [DependencyUpdateItem]) async {
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

  private func auto(items: [DependencyUpdateItem]) async {
    await performMutation("Running auto mode", items: items) { client in
      try await client.autoDependencyUpdates(
        request: DependencyUpdatesAutoRequest(
          targets: items.map(\.target),
          method: normalizedPreferences.mergeMethod
        )
      )
    }
  }

  private func fixCI(item: DependencyUpdateItem) async {
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

  private func performMutation(
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

  private func openItem(_ item: DependencyUpdateItem) {
    guard let url = URL(string: item.url) else { return }
    openURL(url)
  }

  private func copyApprovalLinks(for items: [DependencyUpdateItem]) {
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

  private func relativeUpdatedLabel(for item: DependencyUpdateItem) -> String {
    relativeUpdatedLabels[item.pullRequestID] ?? item.updatedAt
  }

  private func toggleRepositoryCollapse(_ repository: String) {
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
  private func rebuildPresentation(input: DashboardDependenciesPresentationInput) async {
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

// swiftlint:enable type_body_length

struct DashboardDependenciesRepoLabelMenuData: Equatable, Sendable {
  let sortedLabels: [DependencyUpdateRepositoryLabel]
  let frequentNames: [String]
}

@MainActor
private struct DashboardDependenciesRepositorySectionHeader: View {
  let repository: String
  let itemCount: Int
  let isCollapsed: Bool
  let scheduler: DashboardDependenciesScheduler
  let onToggleCollapse: () -> Void

  var body: some View {
    let isSyncing = scheduler.repositoriesInFlight.contains(repository)
    let lastSyncedAt = scheduler.states[repository]?.lastSyncedAt
    Button(action: onToggleCollapse) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
          .font(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .frame(width: 12, alignment: .center)
        Text(repository)
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        if isSyncing {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Syncing \(repository)")
        } else if let lastSyncedAt {
          let relative = dependenciesRelativeFormatter.localizedString(
            for: lastSyncedAt, relativeTo: .now)
          Text("synced \(relative)")
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .accessibilityLabel("Last synced \(relative)")
        }
        Text(verbatim: String(itemCount))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.borderless)
    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
  }
}

@MainActor
private struct DashboardDependenciesDescriptionView: View {
  let store: HarnessMonitorStore
  let pullRequestID: String

  var body: some View {
    switch store.dependencyUpdateBodyState[pullRequestID] {
    case .loaded(let body):
      if body.isEmpty {
        Text("No description")
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .scaledFont(.callout)
      } else {
        HarnessMonitorMarkdownText(body, textSelection: .enabled)
      }
    case .failed(let message):
      Text(message)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .scaledFont(.callout)
    case .loading, nil:
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        ProgressView()
          .controlSize(.small)
        Text("Loading description…")
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .scaledFont(.callout)
      }
    }
  }
}

private struct DashboardDependenciesControlStrip: View {
  @Binding var filterModeRaw: String
  @Binding var sortModeRaw: String
  @Binding var groupModeRaw: String
  let onRefresh: () -> Void
  let onClearCache: () -> Void

  var body: some View {
    HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.spacingSM) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
        HarnessMonitorWrapLayout(
          spacing: HarnessMonitorTheme.spacingSM,
          lineSpacing: HarnessMonitorTheme.spacingSM
        ) {
          filterPicker
          sortPicker
          groupPicker
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        actionsMenu
          .fixedSize(horizontal: true, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var filterPicker: some View {
    Picker("Filter", selection: $filterModeRaw) {
      ForEach(DashboardDependenciesFilterMode.pickerCases) { mode in
        Text(mode.title).tag(mode.rawValue)
      }
    }
    .pickerStyle(.menu)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDependenciesSelectionStatus)
  }

  private var sortPicker: some View {
    Picker("Sort", selection: $sortModeRaw) {
      ForEach(DashboardDependenciesSortMode.pickerCases) { mode in
        Text(mode.title).tag(mode.rawValue)
      }
    }
    .pickerStyle(.menu)
  }

  private var groupPicker: some View {
    Picker("Group", selection: $groupModeRaw) {
      ForEach(DashboardDependenciesGroupMode.pickerCases) { mode in
        Text(mode.title).tag(mode.rawValue)
      }
    }
    .pickerStyle(.menu)
  }

  private var actionsMenu: some View {
    Menu {
      Button(action: onRefresh) {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDependenciesRefreshButton)

      Divider()

      Button(action: onClearCache) {
        Label("Clear Cache", systemImage: "trash")
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .imageScale(.medium)
        .frame(width: 18, height: 18)
        .accessibilityLabel("More dependency actions")
    }
    .menuStyle(.button)
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .accessibilityLabel("More dependency actions")
  }
}

struct DashboardDependenciesRepositoryOrdering {
  let configuredRepositories: [String]
  let configuredOrganizations: [String]

  func compare(_ lhs: String, _ rhs: String) -> Bool {
    sortKey(for: lhs) < sortKey(for: rhs)
  }

  func sorted(_ repositories: [String]) -> [String] {
    repositories.sorted(by: compare)
  }

  private func sortKey(for repository: String) -> DashboardDependenciesRepositorySortKey {
    if let index = configuredRepositories.firstIndex(of: repository) {
      return DashboardDependenciesRepositorySortKey(
        bucket: 0,
        configuredIndex: index,
        organization: repositoryOwner(for: repository),
        repository: repository
      )
    }
    let organization = repositoryOwner(for: repository)
    if let index = configuredOrganizations.firstIndex(of: organization) {
      return DashboardDependenciesRepositorySortKey(
        bucket: 1,
        configuredIndex: index,
        organization: organization,
        repository: repository
      )
    }
    return DashboardDependenciesRepositorySortKey(
      bucket: 2,
      configuredIndex: Int.max,
      organization: organization,
      repository: repository
    )
  }

  private func repositoryOwner(for repository: String) -> String {
    repository.split(separator: "/", maxSplits: 1).first.map(String.init) ?? repository
  }
}

struct DashboardDependenciesCollapsedRepositories: Codable, Equatable {
  var repositories: [String] = []

  var encodedString: String {
    DashboardDependenciesStorageCodec.encodeToString(self)
  }

  func contains(_ repository: String) -> Bool {
    repositories.contains(repository)
  }

  mutating func toggle(_ repository: String) {
    if let index = repositories.firstIndex(of: repository) {
      repositories.remove(at: index)
    } else {
      repositories.append(repository)
      repositories.sort { $0.localizedStandardCompare($1) == .orderedAscending }
    }
  }

  static func decode(from string: String) -> Self {
    DashboardDependenciesStorageCodec.decode(Self.self, from: string) ?? Self()
  }
}

private struct DashboardDependenciesRepositorySortKey: Comparable {
  let bucket: Int
  let configuredIndex: Int
  let organization: String
  let repository: String

  static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.bucket != rhs.bucket {
      return lhs.bucket < rhs.bucket
    }
    if lhs.configuredIndex != rhs.configuredIndex {
      return lhs.configuredIndex < rhs.configuredIndex
    }
    if lhs.organization != rhs.organization {
      return lhs.organization.localizedStandardCompare(rhs.organization) == .orderedAscending
    }
    return lhs.repository.localizedStandardCompare(rhs.repository) == .orderedAscending
  }
}

enum DashboardDependenciesFilterMode: String, CaseIterable, Identifiable {
  case all
  case ready
  case review
  case waiting
  case blocked

  static let pickerCases: [Self] = [.all, .ready, .review, .waiting, .blocked]

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: "All"
    case .ready: "Ready"
    case .review: "Review"
    case .waiting: "Waiting"
    case .blocked: "Blocked"
    }
  }

  func matches(_ item: DependencyUpdateItem) -> Bool {
    switch self {
    case .all: true
    case .ready: item.isAutoMergeable
    case .review: item.reviewStatus == .reviewRequired
    case .waiting: item.checkStatus == .pending
    case .blocked: item.requiresAttention
    }
  }
}

enum DashboardDependenciesSortMode: String, CaseIterable, Identifiable {
  case status
  case age
  case repository

  static let pickerCases: [Self] = [.status, .age, .repository]

  var id: String { rawValue }

  var title: String {
    switch self {
    case .status: "Status"
    case .age: "Age"
    case .repository: "Repository"
    }
  }

  var comparator: (DependencyUpdateItem, DependencyUpdateItem) -> Bool {
    switch self {
    case .status:
      { lhs, rhs in
        if lhs.statusWeight == rhs.statusWeight {
          return lhs.repository.localizedStandardCompare(rhs.repository) == .orderedAscending
        }
        return lhs.statusWeight < rhs.statusWeight
      }
    case .age:
      { lhs, rhs in lhs.createdAt > rhs.createdAt }
    case .repository:
      { lhs, rhs in lhs.repository.localizedStandardCompare(rhs.repository) == .orderedAscending }
    }
  }
}

private enum DashboardDependenciesGroupMode: String, CaseIterable, Identifiable {
  case repository
  case flat

  static let pickerCases: [Self] = [.repository, .flat]

  var id: String { rawValue }

  var title: String {
    switch self {
    case .repository: "By Repo"
    case .flat: "Flat"
    }
  }
}

extension DependencyUpdateItem {
  var statusWeight: Int {
    switch true {
    case reviewStatus == .approved && checkStatus == .success:
      0
    case checkStatus == .pending:
      1
    case reviewStatus == .reviewRequired:
      2
    case checkStatus == .failure:
      3
    case mergeable == .conflicting:
      4
    default:
      5
    }
  }

  var statusLabel: String {
    switch true {
    case isAutoMergeable: "Ready to merge"
    case isAutoApprovable: "Ready for approval"
    case checkStatus == .pending: "Checks running"
    case requiresAttention: "Needs attention"
    default: "Open"
    }
  }

  var statusTint: Color {
    switch true {
    case isAutoMergeable: HarnessMonitorTheme.success
    case isAutoApprovable: HarnessMonitorTheme.accent
    case checkStatus == .pending: HarnessMonitorTheme.caution
    case requiresAttention: HarnessMonitorTheme.danger
    default: HarnessMonitorTheme.secondaryInk
    }
  }

  var statusSystemImage: String {
    switch true {
    case isAutoMergeable: "checkmark.circle.fill"
    case isAutoApprovable: "checkmark.seal.fill"
    case checkStatus == .pending: "clock.arrow.circlepath"
    case requiresAttention: "exclamationmark.triangle.fill"
    default: "circle"
    }
  }

}

extension DependencyUpdateReviewStatus {
  var label: String {
    switch self {
    case .approved: "Approved"
    case .reviewRequired: "Review required"
    case .changesRequested: "Changes requested"
    case .none, .unknown: "No review"
    }
  }

  var tint: Color {
    switch self {
    case .approved: HarnessMonitorTheme.success
    case .reviewRequired: HarnessMonitorTheme.accent
    case .changesRequested: HarnessMonitorTheme.danger
    case .none, .unknown: HarnessMonitorTheme.secondaryInk
    }
  }
}

extension DependencyUpdateCheckStatus {
  var label: String {
    switch self {
    case .none: "No checks"
    case .success: "Checks passing"
    case .failure: "Checks failing"
    case .pending: "Checks pending"
    case .unknown(let raw): raw
    }
  }
}

extension DependencyUpdateCheck {
  var statusLabel: String {
    switch status {
    case .completed: conclusion.label
    case .inProgress: "In progress"
    case .queued: "Queued"
    case .requested: "Requested"
    case .waiting: "Waiting"
    case .unknown: status.rawValue
    }
  }

  var tint: Color {
    switch conclusion {
    case .success: HarnessMonitorTheme.success
    case .failure, .cancelled, .timedOut, .actionRequired, .startupFailure:
      HarnessMonitorTheme.danger
    case .none, .neutral, .skipped, .stale, .unknown:
      HarnessMonitorTheme.secondaryInk
    }
  }
}

extension DependencyUpdateCheckConclusion {
  var label: String {
    switch self {
    case .success: "Success"
    case .failure: "Failure"
    case .neutral: "Neutral"
    case .cancelled: "Cancelled"
    case .timedOut: "Timed out"
    case .actionRequired: "Action required"
    case .skipped: "Skipped"
    case .stale: "Stale"
    case .startupFailure: "Startup failure"
    case .none, .unknown: "Unknown"
    }
  }
}

extension DependencyUpdateReviewEventState {
  var label: String {
    switch self {
    case .approved: "Approved"
    case .changesRequested: "Changes requested"
    case .commented: "Commented"
    case .dismissed: "Dismissed"
    case .pending: "Pending"
    case .unknown: "Unknown"
    }
  }

  var tint: Color {
    switch self {
    case .approved: HarnessMonitorTheme.success
    case .changesRequested: HarnessMonitorTheme.danger
    case .commented, .dismissed, .pending, .unknown: HarnessMonitorTheme.secondaryInk
    }
  }
}

extension String {
  fileprivate var nonEmpty: String? {
    isEmpty ? nil : self
  }
}

extension Array where Element == String {
  func removingDuplicates() -> [String] {
    var seen = Set<String>()
    return filter { seen.insert($0).inserted }
  }
}
