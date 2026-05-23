import HarnessMonitorKit
import SwiftUI

/// `route*` computed properties exposed to the extension files in this
/// directory. They proxy through `routeState` so the `+Refresh`,
/// `+Content`, `+ContextMenu`, `+ToolbarSearch`, `+TransientBanners`,
/// and similar companions can read and write the shared state without
/// each one declaring its own `@Binding` plumbing.
extension DashboardReviewsRouteView {
  var routeResponse: ReviewsQueryResponse {
    get { routeState.response }
    nonmutating set { routeState.response = newValue }
  }

  var routeErrorMessage: String? {
    get { routeState.errorMessage }
    nonmutating set { routeState.errorMessage = newValue }
  }

  var routeIsLoading: Bool {
    get { routeState.isLoading }
    nonmutating set { routeState.isLoading = newValue }
  }

  var routeIsBackgroundRefreshing: Bool {
    get { routeState.isBackgroundRefreshing }
    nonmutating set { routeState.isBackgroundRefreshing = newValue }
  }

  var routeSelectedIDs: Set<String> {
    get { routeState.selectedIDs }
    nonmutating set { routeState.selectedIDs = newValue }
  }

  var routeSelectedIDsBinding: Binding<Set<String>> {
    Binding(
      get: { routeState.selectedIDs },
      set: { routeState.selectedIDs = $0 }
    )
  }

  var routeIsLabelSheetPresented: Bool {
    get { routeState.isLabelSheetPresented }
    nonmutating set { routeState.isLabelSheetPresented = newValue }
  }

  var routeIsLabelSheetPresentedBinding: Binding<Bool> {
    Binding(
      get: { routeState.isLabelSheetPresented },
      set: { routeState.isLabelSheetPresented = $0 }
    )
  }

  var routeLabelDraft: String {
    get { routeState.labelDraft }
    nonmutating set { routeState.labelDraft = newValue }
  }

  var routeLabelDraftBinding: Binding<String> {
    Binding(
      get: { routeState.labelDraft },
      set: { routeState.labelDraft = $0 }
    )
  }

  var routeLabelTargetItems: [ReviewItem] {
    get { routeState.labelTargetItems }
    nonmutating set { routeState.labelTargetItems = newValue }
  }

  var routeLastStoredPreferencesHash: Int? {
    get { routeState.lastStoredPreferencesHash }
    nonmutating set { routeState.lastStoredPreferencesHash = newValue }
  }

  var routeNeedsMeCount: Int {
    get { routeState.needsMeCount }
    nonmutating set { routeState.needsMeCount = newValue }
  }

  var routeRefreshTracker: ReviewRefreshTracker {
    get { routeState.refreshTracker }
    nonmutating set { routeState.refreshTracker = newValue }
  }

  var routeInFlightTasks: [Task<Void, Never>] {
    get { routeState.inFlightTasks }
    nonmutating set { routeState.inFlightTasks = newValue }
  }

  var routeRefreshTimeoutItems: [ReviewItem]? {
    get { routeState.refreshTimeoutItems }
    nonmutating set { routeState.refreshTimeoutItems = newValue }
  }

  var routeDisappearedDescriptors: [DashboardReviewsDisappearedItemTracker.Descriptor] {
    get { routeState.disappearedDescriptors }
    nonmutating set { routeState.disappearedDescriptors = newValue }
  }

  var routeScheduler: DashboardReviewsScheduler {
    routeState.scheduler
  }

  var routeCollapsedRepositories: DashboardReviewsCollapsedRepositories {
    get { routeState.collapsedRepositories }
    nonmutating set { routeState.collapsedRepositories = newValue }
  }

  var routeCollapsedRepositoriesStorage: String {
    get { collapsedRepositoriesStorage }
    nonmutating set { collapsedRepositoriesStorage = newValue }
  }

  var routeLabelMenuDataByRepository: [String: DashboardReviewsRepoLabelMenuData] {
    get { routeState.labelMenuDataByRepository }
    nonmutating set { routeState.labelMenuDataByRepository = newValue }
  }

  var routePinnedPullRequestIDsStorage: String {
    get { pinnedPullRequestIDsStorage }
    nonmutating set { pinnedPullRequestIDsStorage = newValue }
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
    routeState.presentationWorker
  }

  var routeCachedPresentation: DashboardReviewsPresentation {
    get { routeState.cachedPresentation }
    nonmutating set { routeState.cachedPresentation = newValue }
  }

  var routePresentationGeneration: UInt64 {
    get { routeState.presentationGeneration }
    nonmutating set { routeState.presentationGeneration = newValue }
  }

  var routeIsReviewsRouteActive: Bool {
    get { routeState.isReviewsRouteActive }
    nonmutating set { routeState.isReviewsRouteActive = newValue }
  }

  var routePendingResumeAfterReturn: Bool {
    get { routeState.pendingResumeAfterReturn }
    nonmutating set { routeState.pendingResumeAfterReturn = newValue }
  }

  var routeResolvedPreferences: DashboardReviewsResolvedPreferences {
    get { routeState.resolvedPreferences }
    nonmutating set { routeState.resolvedPreferences = newValue }
  }

  var routeRecentReviewActions: [String: DashboardReviewActivityEntry] {
    get { routeState.actionState.recentActions }
    nonmutating set { routeState.actionState.recentActions = newValue }
  }

  var routePinnedPullRequests: DashboardReviewsPinnedPullRequests {
    get { routeState.pinnedPullRequests }
    nonmutating set { routeState.pinnedPullRequests = newValue }
  }

  var routePendingActionConfirmation: DashboardReviewActionConfirmation? {
    get { routeState.actionState.pendingConfirmation }
    nonmutating set { routeState.actionState.pendingConfirmation = newValue }
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
    get { routeState.actionState.capabilities }
    nonmutating set { routeState.actionState.capabilities = newValue }
  }
}
