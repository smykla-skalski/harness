import Foundation
import HarnessMonitorKit
import SwiftUI

enum DashboardReviewsDetailWidthStorage {
  static let storageKey = "dashboard.reviews.content-detail-width"
  static let defaultWidth = SessionContentDetailSplitLayout.defaultContentWidth
}

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
  @Environment(\.globalWindowNavigationHistory)
  var windowNavigationHistory

  @AppStorage(DashboardReviewsPreferences.storageKey)
  var storedPreferences = ""
  @AppStorage("dashboard.reviews.recent-actions")
  var recentReviewActionsStorage = ""
  @AppStorage(DashboardReviewsPinnedPullRequests.storageKey)
  var pinnedPullRequestIDsStorage = ""
  @AppStorage(DashboardReviewsPinnedRepositories.storageKey)
  var pinnedRepositoriesStorage = ""
  @AppStorage(DashboardReviewsSnoozedPullRequests.storageKey)
  var snoozedPullRequestsStorage = ""
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
  @SceneStorage("dashboard.reviews.show-snoozed-only")
  var showSnoozedOnly = false
  @SceneStorage("dashboard.reviews.search")
  var searchText = ""
  @SceneStorage("dashboard.reviews.primary-selection")
  var persistedPrimarySelectionID = ""
  @SceneStorage("dashboard.reviews.collapsed-repositories")
  var collapsedRepositoriesStorage = ""
  @SceneStorage("dashboard.reviews.collapsed-secondary-queues")
  var collapsedSecondaryQueuesStorage = ""
  @AppStorage(DashboardReviewsDetailWidthStorage.storageKey)
  var contentDetailWidth = DashboardReviewsDetailWidthStorage.defaultWidth
  @SceneStorage("dashboard.reviews.problem-checks-only")
  var showsProblemChecksOnly = false
  @SceneStorage("dashboard.reviews.detail-mode")
  var detailModeRaw = DashboardReviewsDetailMode.overview.rawValue
  @SceneStorage("dashboard.reviews.file-selections")
  var fileSelectionsRaw = ""

  @State private var routeState: DashboardReviewsRouteViewState
  @State private var reviewsPreferencesStore = ReviewsPreferencesStore()

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
        ),
        pinnedRepositories: DashboardReviewsPinnedRepositories(
          storedValue: UserDefaults.standard.string(
            forKey: DashboardReviewsPinnedRepositories.storageKey
          ) ?? ""
        ),
        snoozedPullRequests: DashboardReviewsSnoozedPullRequests(
          storedValue: UserDefaults.standard.string(
            forKey: DashboardReviewsSnoozedPullRequests.storageKey
          ) ?? ""
        )
      )
    )
  }

  var routeStateStorage: DashboardReviewsRouteViewState {
    routeState
  }

  var routeReviewsPreferencesStore: ReviewsPreferencesStore {
    reviewsPreferencesStore
  }

  var routeOpenAnythingReviews: OpenAnythingDashboardReviewRegistry {
    openAnythingReviews
  }

  var body: some View {
    let splitView =
      ViewBodySignposter.trace(Self.self, "DashboardReviewsRouteView") {
        SessionContentDetailSplitView(
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
        .environment(\.reviewsPreferences, reviewsPreferencesStore)
        .task(id: reloadTaskKey) {
          await reload(forceRefresh: false)
        }
        .task(id: presentationTaskID) {
          await rebuildPresentation(input: listPresentationInput)
        }
      }

    splitView
      .sheet(isPresented: routeIsLabelSheetPresentedBinding) {
        labelSheet
      }
      .dashboardReviewsPastedTextReviewSheet(
        state: routePastedTextReviewSheetBinding,
        onApprove: approvePastedTextReviewItems,
        onAuto: autoPastedTextReviewItems,
        onSelect: selectPastedTextReviewItem,
        onCopy: copyPastedReviewList
      )
      .confirmationDialog(
        routePendingActionConfirmationTitle,
        isPresented: routeActionDialogPresented,
        titleVisibility: .visible,
        presenting: routePendingActionConfirmation
      ) { confirmation in
        reviewActionConfirmationButton(confirmation)
        Button("Cancel", role: .cancel) {
          routePendingActionConfirmation = nil
        }
      } message: { confirmation in
        Text(confirmation.message)
      }
      .onAppear {
        applyLegacyFilterMigrationIfNeeded()
        consumePendingReviewScreenshotPasteRequest()
      }
      .onReceive(
        NotificationCenter.default.publisher(
          for: DashboardReviewsScreenshotPasteboardRequests.changedNotification
        )
      ) { _ in
        consumePendingReviewScreenshotPasteRequest()
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
        if newValue.count != 1, routeDetailMode == .files {
          routeDetailMode = .overview
        }
        if newValue.count == 1 {
          prefetchSelectedBodies(adding: added)
          prefetchSelectedFiles(adding: added)
        }
        recordCurrentHistorySelectionIfVisible()
      }
      .onChange(of: presentationSelectionID, initial: true) { _, _ in
        refreshCachedPresentationSelection()
      }
      .onChange(of: storedPreferences, initial: true) { _, newValue in
        syncPreferencesFromStorage(newValue)
      }
      .onChange(of: groupModeRaw) { _, newValue in
        var nextPreferences = DashboardReviewsPreferences.decode(from: storedPreferences)
        guard nextPreferences.preferredGroupModeRaw != newValue else { return }
        nextPreferences.preferredGroupModeRaw = newValue
        storedPreferences = nextPreferences.encodedString
      }
      .onChange(of: recentReviewActionsStorage, initial: true) { _, newValue in
        syncRecentReviewActionsFromStorage(newValue)
      }
      .onChange(of: pinnedPullRequestIDsStorage, initial: true) { _, newValue in
        syncPinnedPullRequestsFromStorage(newValue)
      }
      .onChange(of: pinnedRepositoriesStorage, initial: true) { _, newValue in
        syncPinnedRepositoriesFromStorage(newValue)
      }
      .onChange(of: snoozedPullRequestsStorage, initial: true) { _, newValue in
        syncSnoozedPullRequestsFromStorage(newValue)
      }
      .onChange(of: collapsedRepositoriesStorage, initial: true) { _, newValue in
        syncCollapsedRepositoriesFromStorage(newValue)
      }
      .onChange(of: collapsedSecondaryQueuesStorage, initial: true) { _, newValue in
        syncCollapsedSecondaryQueuesFromStorage(newValue)
      }
      .onChange(of: routeResponse.repositoryLabels, initial: true) { _, _ in
        refreshLabelMenuData()
      }
      .onChange(of: routeResponse.items, initial: true) { _, items in
        openAnythingReviews.replaceLoadedItems(items)
        // Repositories surfaced by cache/response but absent from the resolver
        // still need scheduler state so they don't get stuck at "Never synced".
        trackVisibleRepositories(items)
        // Pending Open Anything requests that fired before items finished
        // loading need a second chance once the items arrive. The helper is
        // idempotent: `finishSelection` clears the request, so a follow-up
        // task-triggered call is a no-op.
        applyPendingReviewSelectionIfNeeded()
        routeState.needsMeCount = Self.recomputeNeedsMeCount(items: items)
        // Run the disappeared-item diff after every items change. The first
        // call after appearance is silently swallowed by the tracker so the
        // initial response never emits audit-only entries for items the user has not
        // previously observed.
        let descriptors = routeState.disappearedTracker.diff(currentItems: items)
        if !descriptors.isEmpty {
          let recordedAt = Date.now
          Task { @MainActor in
            for descriptor in descriptors {
              await store.recordNotificationHistoryEntry(
                descriptor.notificationHistoryEntry(recordedAt: recordedAt)
              )
            }
          }
        }
        Task {
          await applyPendingDashboardReviewsRestoreIfNeeded()
        }
      }
      .onChange(of: routeState.needsMeCount) { _, newValue in
        // Skip while the scheduler is paginating through repos so we don't
        // publish intermediate counts (0 -> 57 -> 65 -> ...). The follow-up
        // onChange below pushes the settled count once `repositoriesInFlight`
        // empties.
        guard routeScheduler.repositoriesInFlight.isEmpty else { return }
        NeedsMeCloudKitWriter.shared.submit(count: newValue)
      }
      .onChange(of: routeScheduler.repositoriesInFlight) { _, newValue in
        guard newValue.isEmpty else { return }
        NeedsMeCloudKitWriter.shared.submit(count: routeState.needsMeCount)
      }
      .onChange(of: normalizedPreferences.frequentLabelsCount) { _, _ in
        refreshLabelMenuData()
      }
      .onChange(of: detailModeRaw) { _, _ in
        recordCurrentHistorySelectionIfVisible()
      }
      .onChange(of: filesModePrimarySelectedPath) { _, _ in
        recordCurrentHistorySelectionIfVisible()
      }
      .onChange(of: filesModePrimaryLineSelection) { _, _ in
        recordCurrentHistorySelectionIfVisible()
      }
      .task(id: openAnythingReviews.selectionRequest) {
        applyPendingReviewSelectionIfNeeded()
      }
      .task(id: windowNavigationHistory?.pendingDashboardReviewsRestoreRequest) {
        await applyPendingDashboardReviewsRestoreIfNeeded()
      }
      .task {
        recordCurrentHistorySelectionIfVisible()
      }
      .onChange(of: selectedRoute) { _, newValue in
        handleSelectedRouteChange(newValue)
        recordCurrentHistorySelectionIfVisible()
        Task {
          await applyPendingDashboardReviewsRestoreIfNeeded()
        }
      }
      .dashboardReviewsOnSystemWake(perform: handleSystemWake)
      .dashboardReviewsToolbarSearch(
        query: $searchText,
        items: routeResponse.items,
        itemsVersion: routeResponseItemsVersion,
        automationCommand: searchAutomationCommand
      ) { pullRequestID in
        routeSelectedIDs = [pullRequestID]
      }
      .harnessFocusedSceneValue(\.dashboardReviewsCommands, reviewCommandFocus)
  }
}
