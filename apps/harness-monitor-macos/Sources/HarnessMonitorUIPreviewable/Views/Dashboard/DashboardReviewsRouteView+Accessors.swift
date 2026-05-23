import HarnessMonitorKit
import SwiftUI

/// `route*` computed properties exposed to the extension files in this
/// directory. They wrap the route view's `@State` storage so the
/// `+Refresh`, `+Content`, `+ContextMenu`, `+ToolbarSearch`,
/// `+TransientBanners`, and similar companions can read and write the
/// shared state without each one declaring its own `@Binding` plumbing.
extension DashboardReviewsRouteView {
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

  var routeLastStoredPreferencesHash: Int? {
    get { lastStoredPreferencesHash }
    nonmutating set { lastStoredPreferencesHash = newValue }
  }

  var routeNeedsMeCount: Int {
    get { needsMeCount }
    nonmutating set { needsMeCount = newValue }
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

  var routeDisappearedDescriptors: [DashboardReviewsDisappearedItemTracker.Descriptor] {
    get { disappearedDescriptors }
    nonmutating set { disappearedDescriptors = newValue }
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
}
