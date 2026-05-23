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
  @AppStorage(DashboardReviewsPinnedPullRequests.storageKey)
  var pinnedPullRequestIDsStorage = ""
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

  @State private var routeState: DashboardReviewsRouteViewState

  init(
    store: HarnessMonitorStore,
    selectedRoute: Binding<DashboardWindowRoute>,
    searchAutomationCommand: AppSearchAutomationCommand? = nil
  ) {
    self.store = store
    _selectedRoute = selectedRoute
    self.searchAutomationCommand = searchAutomationCommand
    _routeState = State(
      initialValue: DashboardReviewsRouteViewState(
        resolvedPreferences: DashboardReviewsResolvedPreferences(
          storedValue: UserDefaults.standard.string(
            forKey: DashboardReviewsPreferences.storageKey
          ) ?? ""
        ),
        pinnedPullRequests: DashboardReviewsPinnedPullRequests(
          storedValue: UserDefaults.standard.string(
            forKey: DashboardReviewsPinnedPullRequests.storageKey
          ) ?? ""
        )
      )
    )
  }

  var reloadTaskKey: DashboardReviewsReloadTaskKey {
    DashboardReviewsReloadTaskKey(
      preferencesSignature: routeResolvedPreferences.cacheHash,
      isConnected: isReviewsReloadConnected(store.connectionState)
    )
  }

  var normalizedPreferences: DashboardReviewsPreferences {
    routeResolvedPreferences.preferences
  }

  var routeStateStorage: DashboardReviewsRouteViewState {
    routeState
  }

  var groupMode: DashboardReviewsGroupMode {
    DashboardReviewsGroupMode(rawValue: groupModeRaw) ?? .repository
  }

  var presentationInput: DashboardReviewsPresentationInput {
    let preferences = routeResolvedPreferences
    return DashboardReviewsPresentationInput(
      items: routeResponse.items,
      filterModeRaw: filterModeRaw,
      sortModeRaw: sortModeRaw,
      groupModeRaw: groupModeRaw,
      categoryModeRaw: categoryModeRaw,
      searchText: searchText,
      configuredRepositories: preferences.repositories,
      configuredOrganizations: preferences.organizations,
      configuredAuthors: preferences.authors,
      selectedIDs: routeSelectedIDs,
      persistedPrimarySelectionID: persistedPrimarySelectionID,
      pinnedPullRequestIDs: routePinnedPullRequests.pullRequestIDs,
      needsMeOn: needsMeOn,
      dependenciesOnlyOn: dependenciesOnlyOn
    )
  }

  var filteredItems: [ReviewItem] {
    routeCachedPresentation.filteredItems
  }

  var groupedItems: [DashboardReviewsRepositoryGroup] {
    routeCachedPresentation.groupedItems
  }

  var selectedItems: [ReviewItem] {
    routeCachedPresentation.selectedItems
  }

  var primaryDetailItem: ReviewItem? {
    routeCachedPresentation.primaryDetailItem
  }

  var relativeUpdatedLabels: [String: String] {
    routeCachedPresentation.relativeUpdatedLabels
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
      .sheet(isPresented: routeIsLabelSheetPresentedBinding) {
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
      .onChange(of: routeSelectedIDs) { oldValue, newValue in
        let nextPrimary = DashboardReviewsPrimarySelectionResolver.resolve(
          oldSelection: oldValue,
          newSelection: newValue,
          currentPrimary: persistedPrimarySelectionID
        )
        persistedPrimarySelectionID = nextPrimary
        let added = newValue.subtracting(oldValue)
        if added.count == 1 {
          routeState.lastPrimaryClickedID = added.first
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
      .onChange(of: pinnedPullRequestIDsStorage, initial: true) { _, newValue in
        syncPinnedPullRequestsFromStorage(newValue)
      }
      .onChange(of: collapsedRepositoriesStorage, initial: true) { _, newValue in
        syncCollapsedRepositoriesFromStorage(newValue)
      }
      .onChange(of: routeResponse.repositoryLabels, initial: true) { _, _ in
        refreshLabelMenuData()
      }
      .onChange(of: routeResponse.items, initial: true) { _, items in
        openAnythingReviews.replaceLoadedItems(items)
        // Pending Open Anything requests that fired before items finished
        // loading need a second chance once the items arrive. The helper is
        // idempotent: `finishSelection` clears the request, so a follow-up
        // task-triggered call is a no-op.
        applyPendingReviewSelectionIfNeeded()
        routeState.needsMeCount = Self.recomputeNeedsMeCount(items: items)
        // Run the disappeared-item diff after every items change. The first
        // call after appearance is silently swallowed by the tracker so the
        // initial response never emits toasts for items the user has not
        // previously observed.
        let descriptors = routeState.disappearedTracker.diff(currentItems: items)
        if !descriptors.isEmpty {
          routeState.disappearedDescriptors.append(contentsOf: descriptors)
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
        items: routeResponse.items,
        automationCommand: searchAutomationCommand
      ) { pullRequestID in
        routeSelectedIDs = [pullRequestID]
      }
      .focusedSceneValue(\.dashboardReviewsCommands, reviewCommandFocus)
  }

  private func applyPendingReviewSelectionIfNeeded() {
    guard let request = openAnythingReviews.selectionRequest else { return }
    guard routeResponse.items.contains(where: { $0.pullRequestID == request.pullRequestID }) else {
      return
    }
    routeSelectedIDs = [request.pullRequestID]
    persistedPrimarySelectionID = request.pullRequestID
    openAnythingReviews.finishSelection(requestID: request.requestID)
  }

  // Legacy filter values - `"blocked"` filter and `"dependencies"` category -
  // migrate once per session to the new toggle-based flags.
  private func applyLegacyFilterMigrationIfNeeded() {
    guard !routeState.legacyFilterMigrationApplied else { return }
    routeState.legacyFilterMigrationApplied = true
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
