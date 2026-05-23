import HarnessMonitorKit
import SwiftUI

@MainActor
struct DashboardReviewsRouteView: View {
  let store: HarnessMonitorStore
  @Binding var selectedRoute: DashboardWindowRoute
  let searchAutomationCommand: AppSearchAutomationCommand?

  @Environment(\.openAnythingDashboardReviewRegistry)
  private var openAnythingReviews
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

  @State var response = ReviewsQueryResponse(
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
  @State var isLoading = false
  @State var isBackgroundRefreshing = false
  @State var errorMessage: String?
  @State var selectedIDs = Set<String>()
  @State var isLabelSheetPresented = false
  @State var labelDraft = ""
  @State var labelTargetItems = [ReviewItem]()
  @State var resolvedPreferences: DashboardReviewsResolvedPreferences
  @State var presentationWorker = DashboardReviewsPresentationWorker()
  @State var cachedPresentation = DashboardReviewsPresentation.empty
  @State var presentationGeneration: UInt64 = 0
  @State var refreshTracker = ReviewRefreshTracker()
  @State var inFlightTasks: [Task<Void, Never>] = []
  /// The set of items whose most recent targeted refresh timed out. Drives
  /// the inline tap-to-retry banner mounted in the content pane. Set when
  /// `scheduleAffectedRefresh` catches `DashboardReviewsSchedulerError`,
  /// cleared on retry, dismissal, or successful refresh of the same items.
  @State var refreshTimeoutItems: [ReviewItem]?
  /// Tracker that compares the previous and current response item sets to
  /// surface a one-shot toast for each pull request that disappeared
  /// (merged, closed, or fell out of scope). The first call after view
  /// appearance establishes a silent baseline.
  @State var disappearedTracker = DashboardReviewsDisappearedItemTracker()
  /// Disappeared-item descriptors emitted on the most recent items-arrival
  /// diff. Consumed by the transient-banner zone in the content pane and
  /// cleared once the user dismisses the banner.
  @State var disappearedDescriptors: [DashboardReviewsDisappearedItemTracker.Descriptor] = []
  @State var scheduler = DashboardReviewsScheduler()
  @State var collapsedRepositories = DashboardReviewsCollapsedRepositories()
  @State var labelMenuDataByRepository: [String: DashboardReviewsRepoLabelMenuData] =
    [:]
  @State var actionState = DashboardReviewsRouteActionState()
  @State var legacyFilterMigrationApplied = false
  @State var lastPrimaryClickedID: String?
  @State var isReviewsRouteActive = true
  @State var pendingResumeAfterReturn = false
  // Skip the JSON decode in `syncPreferencesFromStorage` when the raw stored
  // string is byte-identical to the last value we already decoded. The
  // `.onChange(of: storedPreferences)` handler fires `initial: true` and
  // re-fires on every UserDefaults write the surface emits; the decode itself
  // is non-trivial.
  @State var lastStoredPreferencesHash: Int?
  @State var needsMeCount: Int = 0

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
        needsMeCount = DashboardReviewsRouteView.recomputeNeedsMeCount(items: items)
        // Run the disappeared-item diff after every items change. The first
        // call after appearance is silently swallowed by the tracker so the
        // initial response never emits toasts for items the user has not
        // previously observed.
        let descriptors = disappearedTracker.diff(currentItems: items)
        if !descriptors.isEmpty {
          disappearedDescriptors.append(contentsOf: descriptors)
        }
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
