import HarnessMonitorKit
import SwiftUI

@MainActor
struct DashboardReviewsRouteView: View {
  let store: HarnessMonitorStore
  @Binding var selectedRoute: DashboardWindowRoute
  let searchAutomationCommand: AppSearchAutomationCommand?
  private let openAnythingReviews = OpenAnythingDashboardReviewRegistry.shared

  @Environment(\.openSettingsSection)
  var openSettingsSection
  @Environment(\.openURL)
  var openURL

  @AppStorage(DashboardReviewsPreferences.storageKey)
  var storedPreferences = ""
  @AppStorage("dashboard.reviews.recent-actions")
  var recentReviewActionsStorage = ""
  @SceneStorage("dashboard.reviews.filter")
  var filterModeRaw = DashboardReviewsFilterMode.all.rawValue
  @SceneStorage("dashboard.reviews.sort")
  var sortModeRaw = DashboardReviewsSortMode.status.rawValue
  @SceneStorage("dashboard.reviews.group")
  var groupModeRaw = DashboardReviewsGroupMode.repository.rawValue
  @SceneStorage("dashboard.reviews.category")
  var categoryModeRaw = DashboardReviewsCategoryMode.all.rawValue
  @SceneStorage("dashboard.reviews.needs-me")
  var needsMeOn = false
  @SceneStorage("dashboard.reviews.dependencies-only")
  var dependenciesOnlyOn = false
  @SceneStorage("dashboard.reviews.search")
  var searchText = ""
  @SceneStorage("dashboard.reviews.primary-selection")
  var persistedPrimarySelectionID = ""
  @SceneStorage("dashboard.reviews.collapsed-repositories")
  var collapsedRepositoriesStorage = ""
  @SceneStorage("dashboard.reviews.content-detail-width")
  var contentDetailWidth = SessionContentDetailSplitLayout.defaultContentWidth
  @SceneStorage("dashboard.reviews.problem-checks-only")
  var showsProblemChecksOnly = false

  @State private var response = ReviewsQueryResponse(
    fetchedAt: "",
    fromCache: false,
    summary: ReviewsSummary(
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
  @State private var labelTargetItems = [ReviewItem]()
  @State private var resolvedPreferences: DashboardReviewsResolvedPreferences
  @State private var presentationWorker = DashboardReviewsPresentationWorker()
  @State private var cachedPresentation = DashboardReviewsPresentation.empty
  @State private var presentationGeneration: UInt64 = 0
  @State private var refreshTracker = ReviewRefreshTracker()
  @State private var inFlightTasks: [Task<Void, Never>] = []
  /// The set of items whose most recent targeted refresh timed out. Drives
  /// the inline tap-to-retry banner mounted in the content pane. Set when
  /// `scheduleAffectedRefresh` catches `DashboardReviewsSchedulerError`,
  /// cleared on retry, dismissal, or successful refresh of the same items.
  @State private var refreshTimeoutItems: [ReviewItem]?
  @State private var scheduler = DashboardReviewsScheduler()
  @State private var collapsedRepositories = DashboardReviewsCollapsedRepositories()
  @State private var labelMenuDataByRepository: [String: DashboardReviewsRepoLabelMenuData] =
    [:]
  @State private var actionState = DashboardReviewsRouteActionState()
  @State private var legacyFilterMigrationApplied = false
  @State private var lastPrimaryClickedID: String?
  @State private var isReviewsRouteActive = true
  @State private var pendingResumeAfterReturn = false

  init(
    store: HarnessMonitorStore,
    selectedRoute: Binding<DashboardWindowRoute>,
    searchAutomationCommand: AppSearchAutomationCommand? = nil
  ) {
    self.store = store
    _selectedRoute = selectedRoute
    self.searchAutomationCommand = searchAutomationCommand
    _resolvedPreferences = State(
      initialValue: DashboardReviewsResolvedPreferences(
        storedValue: UserDefaults.standard.string(
          forKey: DashboardReviewsPreferences.storageKey
        ) ?? ""
      )
    )
  }

  var routeResponse: ReviewsQueryResponse {
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

  var routeLabelTargetItems: [ReviewItem] {
    get { labelTargetItems }
    nonmutating set { labelTargetItems = newValue }
  }

  var routeResolvedPreferences: DashboardReviewsResolvedPreferences {
    get { resolvedPreferences }
    nonmutating set { resolvedPreferences = newValue }
  }

  var routeRefreshTracker: ReviewRefreshTracker {
    get { refreshTracker }
    nonmutating set { refreshTracker = newValue }
  }

  var routeInFlightTasks: [Task<Void, Never>] {
    get { inFlightTasks }
    nonmutating set { inFlightTasks = newValue }
  }

  var routeRefreshTimeoutItems: [ReviewItem]? {
    get { refreshTimeoutItems }
    nonmutating set { refreshTimeoutItems = newValue }
  }

  var routeScheduler: DashboardReviewsScheduler {
    scheduler
  }

  var routeCollapsedRepositories: DashboardReviewsCollapsedRepositories {
    get { collapsedRepositories }
    nonmutating set { collapsedRepositories = newValue }
  }

  var routeCollapsedRepositoriesStorage: String {
    get { collapsedRepositoriesStorage }
    nonmutating set { collapsedRepositoriesStorage = newValue }
  }

  var routeLabelMenuDataByRepository: [String: DashboardReviewsRepoLabelMenuData] {
    get { labelMenuDataByRepository }
    nonmutating set { labelMenuDataByRepository = newValue }
  }

  var routeRecentReviewActions: [String: DashboardReviewActivityEntry] {
    get { actionState.recentActions }
    nonmutating set { actionState.recentActions = newValue }
  }

  var routePendingActionConfirmation: DashboardReviewActionConfirmation? {
    get { actionState.pendingConfirmation }
    nonmutating set { actionState.pendingConfirmation = newValue }
  }

  var routePendingActionConfirmationTitle: String {
    routePendingActionConfirmation?.title ?? ""
  }

  var routeActionDialogPresented: Binding<Bool> {
    Binding(
      get: { routePendingActionConfirmation != nil },
      set: { isPresented in
        if !isPresented {
          routePendingActionConfirmation = nil
        }
      }
    )
  }

  var routeReviewCapabilities: ReviewsCapabilitiesResponse {
    get { actionState.capabilities }
    nonmutating set { actionState.capabilities = newValue }
  }

  var routeShowsProblemChecksOnlyBinding: Binding<Bool> {
    $showsProblemChecksOnly
  }

  var routeNeedsMeOnBinding: Binding<Bool> {
    $needsMeOn
  }

  var routeDependenciesOnlyOnBinding: Binding<Bool> {
    $dependenciesOnlyOn
  }

  var routePresentationWorker: DashboardReviewsPresentationWorker {
    presentationWorker
  }

  var routeCachedPresentation: DashboardReviewsPresentation {
    get { cachedPresentation }
    nonmutating set { cachedPresentation = newValue }
  }

  var routePresentationGeneration: UInt64 {
    get { presentationGeneration }
    nonmutating set { presentationGeneration = newValue }
  }

  var routeIsReviewsRouteActive: Bool {
    get { isReviewsRouteActive }
    nonmutating set { isReviewsRouteActive = newValue }
  }

  var routePendingResumeAfterReturn: Bool {
    get { pendingResumeAfterReturn }
    nonmutating set { pendingResumeAfterReturn = newValue }
  }

  var reloadTaskKey: DashboardReviewsReloadTaskKey {
    DashboardReviewsReloadTaskKey(
      preferencesSignature: resolvedPreferences.cacheHash,
      isConnected: isReviewsReloadConnected(store.connectionState)
    )
  }

  var normalizedPreferences: DashboardReviewsPreferences {
    resolvedPreferences.preferences
  }

  var groupMode: DashboardReviewsGroupMode {
    DashboardReviewsGroupMode(rawValue: groupModeRaw) ?? .repository
  }

  var presentationInput: DashboardReviewsPresentationInput {
    let preferences = resolvedPreferences
    return DashboardReviewsPresentationInput(
      items: response.items,
      filterModeRaw: filterModeRaw,
      sortModeRaw: sortModeRaw,
      groupModeRaw: groupModeRaw,
      categoryModeRaw: categoryModeRaw,
      searchText: searchText,
      configuredRepositories: preferences.repositories,
      configuredOrganizations: preferences.organizations,
      configuredAuthors: preferences.authors,
      selectedIDs: selectedIDs,
      persistedPrimarySelectionID: persistedPrimarySelectionID,
      needsMeOn: needsMeOn,
      dependenciesOnlyOn: dependenciesOnlyOn
    )
  }

  var filteredItems: [ReviewItem] {
    cachedPresentation.filteredItems
  }

  var groupedItems: [DashboardReviewsRepositoryGroup] {
    cachedPresentation.groupedItems
  }

  var selectedItems: [ReviewItem] {
    cachedPresentation.selectedItems
  }

  var primaryDetailItem: ReviewItem? {
    cachedPresentation.primaryDetailItem
  }

  var relativeUpdatedLabels: [String: String] {
    cachedPresentation.relativeUpdatedLabels
  }

  var body: some View {
    let splitView = SessionContentDetailSplitView(
      contentWidth: $contentDetailWidth,
      commitContentWidth: { contentDetailWidth = $0 },
      dividerAccessibilityIdentifier:
        HarnessMonitorAccessibility.dashboardReviewsDetailDivider,
      showsDividerLine: false,
      content: { contentPane },
      detail: { detailPane }
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsRoot)
    .task(id: reloadTaskKey) {
      await reload(forceRefresh: false)
    }
    .task(id: presentationInput) {
      await rebuildPresentation(input: presentationInput)
    }

    splitView
      .sheet(isPresented: $isLabelSheetPresented) {
        labelSheet
      }
      .confirmationDialog(
        routePendingActionConfirmationTitle,
        isPresented: routeActionDialogPresented,
        titleVisibility: .visible,
        presenting: routePendingActionConfirmation
      ) { confirmation in
        Button(confirmation.confirmButtonTitle, role: confirmation.confirmRole) {
          routePendingActionConfirmation = nil
          confirmReviewAction(confirmation)
        }
        Button("Cancel", role: .cancel) {
          routePendingActionConfirmation = nil
        }
      } message: { confirmation in
        Text(confirmation.message)
      }
      .onAppear {
        applyLegacyFilterMigrationIfNeeded()
      }
      .onChange(of: selectedIDs) { oldValue, newValue in
        let nextPrimary = DashboardReviewsPrimarySelectionResolver.resolve(
          oldSelection: oldValue,
          newSelection: newValue,
          currentPrimary: persistedPrimarySelectionID
        )
        persistedPrimarySelectionID = nextPrimary
        let added = newValue.subtracting(oldValue)
        if added.count == 1 {
          lastPrimaryClickedID = added.first
        }
        prefetchSelectedBodies(adding: added)
        prefetchSelectedFiles(adding: added)
      }
      .onChange(of: storedPreferences, initial: true) { _, newValue in
        syncPreferencesFromStorage(newValue)
      }
      .onChange(of: recentReviewActionsStorage, initial: true) { _, newValue in
        syncRecentReviewActionsFromStorage(newValue)
      }
      .onChange(of: collapsedRepositoriesStorage, initial: true) { _, newValue in
        syncCollapsedRepositoriesFromStorage(newValue)
      }
      .onChange(of: response.repositoryLabels, initial: true) { _, _ in
        refreshLabelMenuData()
      }
      .onChange(of: response.items, initial: true) { _, items in
        openAnythingReviews.replaceLoadedItems(items)
        // Pending Open Anything requests that fired before items finished
        // loading need a second chance once the items arrive. The helper is
        // idempotent: `finishSelection` clears the request, so a follow-up
        // task-triggered call is a no-op.
        applyPendingReviewSelectionIfNeeded()
      }
      .onChange(of: normalizedPreferences.frequentLabelsCount) { _, _ in
        refreshLabelMenuData()
      }
      .task(id: openAnythingReviews.selectionRequest) {
        applyPendingReviewSelectionIfNeeded()
      }
      .onChange(of: selectedRoute) { _, newValue in
        handleSelectedRouteChange(newValue)
      }
      .dashboardReviewsOnSystemWake(perform: handleSystemWake)
      .dashboardReviewsToolbarSearch(
        query: $searchText,
        items: response.items,
        automationCommand: searchAutomationCommand
      ) { pullRequestID in
        selectedIDs = [pullRequestID]
      }
      .focusedSceneValue(\.dashboardReviewsCommands, reviewCommandFocus)
  }

  private func applyPendingReviewSelectionIfNeeded() {
    guard let request = openAnythingReviews.selectionRequest else { return }
    guard response.items.contains(where: { $0.pullRequestID == request.pullRequestID }) else {
      return
    }
    selectedIDs = [request.pullRequestID]
    persistedPrimarySelectionID = request.pullRequestID
    openAnythingReviews.finishSelection(requestID: request.requestID)
  }

  // Legacy filter values - `"blocked"` filter and `"dependencies"` category -
  // migrate once per session to the new toggle-based flags.
  private func applyLegacyFilterMigrationIfNeeded() {
    guard !legacyFilterMigrationApplied else { return }
    legacyFilterMigrationApplied = true
    if filterModeRaw == "blocked" {
      needsMeOn = true
      filterModeRaw = DashboardReviewsFilterMode.all.rawValue
    }
    if categoryModeRaw == DashboardReviewsCategoryMode.dependencies.rawValue {
      dependenciesOnlyOn = true
      categoryModeRaw = DashboardReviewsCategoryMode.defaultMode.rawValue
    }
  }
}
