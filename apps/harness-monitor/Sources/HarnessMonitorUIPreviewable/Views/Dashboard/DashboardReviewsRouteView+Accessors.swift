import HarnessMonitorKit
import SwiftUI

/// `route*` computed properties exposed to the extension files in this
/// directory. They proxy through the private route state storage so the
/// `+Refresh`, `+Content`, `+ContextMenu`, `+ToolbarSearch`,
/// `+TransientBanners`, and similar companions can read and write shared
/// state without each one declaring its own `@Binding` plumbing.
extension DashboardReviewsRouteView {
  var routeResponse: ReviewsQueryResponse {
    get { routeStateStorage.response }
    nonmutating set {
      routeStateStorage.response = newValue
      routeStateStorage.responseItemsRevision &+= 1
    }
  }

  var routeResponseItemsVersion: DashboardReviewsItemsVersion {
    DashboardReviewsItemsVersion(revision: routeStateStorage.responseItemsRevision)
  }

  var routeErrorMessage: String? {
    get { routeStateStorage.errorMessage }
    nonmutating set { routeStateStorage.errorMessage = newValue }
  }

  var routeIsLoading: Bool {
    get { routeStateStorage.isLoading }
    nonmutating set { routeStateStorage.isLoading = newValue }
  }

  var routeIsBackgroundRefreshing: Bool {
    get { routeStateStorage.isBackgroundRefreshing }
    nonmutating set { routeStateStorage.isBackgroundRefreshing = newValue }
  }

  var routeSelectedIDs: Set<String> {
    get { routeStateStorage.selectedIDs }
    nonmutating set { routeStateStorage.selectedIDs = newValue }
  }

  var routeSelectedIDsBinding: Binding<Set<String>> {
    Binding(
      get: { routeStateStorage.selectedIDs },
      set: { routeStateStorage.selectedIDs = $0 }
    )
  }

  var routeIsLabelSheetPresented: Bool {
    get { routeStateStorage.isLabelSheetPresented }
    nonmutating set { routeStateStorage.isLabelSheetPresented = newValue }
  }

  var routeIsLabelSheetPresentedBinding: Binding<Bool> {
    Binding(
      get: { routeStateStorage.isLabelSheetPresented },
      set: { routeStateStorage.isLabelSheetPresented = $0 }
    )
  }

  var routeLabelDraft: String {
    get { routeStateStorage.labelDraft }
    nonmutating set { routeStateStorage.labelDraft = newValue }
  }

  var routeLabelDraftBinding: Binding<String> {
    Binding(
      get: { routeStateStorage.labelDraft },
      set: { routeStateStorage.labelDraft = $0 }
    )
  }

  var routeLabelTargetItems: [ReviewItem] {
    get { routeStateStorage.labelTargetItems }
    nonmutating set { routeStateStorage.labelTargetItems = newValue }
  }

  var routeLastStoredPreferencesHash: Int? {
    get { routeStateStorage.lastStoredPreferencesHash }
    nonmutating set { routeStateStorage.lastStoredPreferencesHash = newValue }
  }

  var routeNeedsMeCount: Int {
    get { routeStateStorage.needsMeCount }
    nonmutating set { routeStateStorage.needsMeCount = newValue }
  }

  var routeRefreshTracker: ReviewRefreshTracker {
    get { routeStateStorage.refreshTracker }
    nonmutating set { routeStateStorage.refreshTracker = newValue }
  }

  var routeInFlightTasks: [Task<Void, Never>] {
    get { routeStateStorage.inFlightTasks }
    nonmutating set { routeStateStorage.inFlightTasks = newValue }
  }

  var routeRefreshTimeoutItems: [ReviewItem]? {
    get { routeStateStorage.refreshTimeoutItems }
    nonmutating set { routeStateStorage.refreshTimeoutItems = newValue }
  }

  var routeDisappearedDescriptors: [DashboardReviewsDisappearedItemTracker.Descriptor] {
    get { routeStateStorage.disappearedDescriptors }
    nonmutating set { routeStateStorage.disappearedDescriptors = newValue }
  }

  var routeScheduler: DashboardReviewsScheduler {
    routeStateStorage.scheduler
  }

  var routeCollapsedRepositories: DashboardReviewsCollapsedRepositories {
    get { routeStateStorage.collapsedRepositories }
    nonmutating set { routeStateStorage.collapsedRepositories = newValue }
  }

  var routeCollapsedRepositoriesStorage: String {
    get { collapsedRepositoriesStorage }
    nonmutating set { collapsedRepositoriesStorage = newValue }
  }

  var routeLabelMenuDataByRepository: [String: DashboardReviewsRepoLabelMenuData] {
    get { routeStateStorage.labelMenuDataByRepository }
    nonmutating set { routeStateStorage.labelMenuDataByRepository = newValue }
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
    routeStateStorage.presentationWorker
  }

  var routeCachedPresentation: DashboardReviewsPresentation {
    get { routeStateStorage.cachedPresentation }
    nonmutating set { routeStateStorage.cachedPresentation = newValue }
  }

  var routePresentationGeneration: UInt64 {
    get { routeStateStorage.presentationGeneration }
    nonmutating set { routeStateStorage.presentationGeneration = newValue }
  }

  var routeIsReviewsRouteActive: Bool {
    get { routeStateStorage.isReviewsRouteActive }
    nonmutating set { routeStateStorage.isReviewsRouteActive = newValue }
  }

  var routePendingResumeAfterReturn: Bool {
    get { routeStateStorage.pendingResumeAfterReturn }
    nonmutating set { routeStateStorage.pendingResumeAfterReturn = newValue }
  }

  var routeHandledHistoryRestoreRequestID: Int {
    get { routeStateStorage.handledDashboardHistoryRestoreRequestID }
    nonmutating set { routeStateStorage.handledDashboardHistoryRestoreRequestID = newValue }
  }

  var routeResolvedPreferences: DashboardReviewsResolvedPreferences {
    get { routeStateStorage.resolvedPreferences }
    nonmutating set { routeStateStorage.resolvedPreferences = newValue }
  }

  var routeRecentReviewActions: [String: DashboardReviewActivityEntry] {
    get { routeStateStorage.actionState.recentActions }
    nonmutating set { routeStateStorage.actionState.recentActions = newValue }
  }

  var routePinnedPullRequests: DashboardReviewsPinnedPullRequests {
    get { routeStateStorage.pinnedPullRequests }
    nonmutating set { routeStateStorage.pinnedPullRequests = newValue }
  }

  var routePendingActionConfirmation: DashboardReviewActionConfirmation? {
    get { routeStateStorage.actionState.pendingConfirmation }
    nonmutating set { routeStateStorage.actionState.pendingConfirmation = newValue }
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
    get { routeStateStorage.actionState.capabilities }
    nonmutating set { routeStateStorage.actionState.capabilities = newValue }
  }
}
