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
      setRouteResponse(newValue, bumpsItemsRevision: true)
    }
  }

  func setRouteResponse(
    _ response: ReviewsQueryResponse,
    bumpsItemsRevision: Bool
  ) {
    routeStateStorage.response = response
    if bumpsItemsRevision {
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

  var routeCollapsedSecondaryQueues: DashboardReviewsCollapsedSecondaryQueues {
    get { routeStateStorage.collapsedSecondaryQueues }
    nonmutating set { routeStateStorage.collapsedSecondaryQueues = newValue }
  }

  func syncSnoozedPullRequestsFromStorage(_ value: String) {
    let parsed = DashboardReviewsSnoozedPullRequests(storedValue: value)
    guard parsed != routeSnoozedPullRequests else { return }
    routeSnoozedPullRequests = parsed
  }

  var routeLabelMenuDataByRepository: [String: DashboardReviewsRepoLabelMenuData] {
    get { routeStateStorage.labelMenuDataByRepository }
    nonmutating set { routeStateStorage.labelMenuDataByRepository = newValue }
  }

  var routeCollapsedRepositoriesStorage: String {
    get { collapsedRepositoriesStorage }
    nonmutating set { collapsedRepositoriesStorage = newValue }
  }

  var routeCollapsedSecondaryQueuesStorage: String {
    get { collapsedSecondaryQueuesStorage }
    nonmutating set { collapsedSecondaryQueuesStorage = newValue }
  }

  var routePinnedPullRequestIDsStorage: String {
    get { pinnedPullRequestIDsStorage }
    nonmutating set { pinnedPullRequestIDsStorage = newValue }
  }

  var routePinnedRepositoriesStorage: String {
    get { pinnedRepositoriesStorage }
    nonmutating set { pinnedRepositoriesStorage = newValue }
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

  var routeShowAvatarsInRowsBinding: Binding<Bool> {
    routePreferencesToggleBinding(\.showAvatarsInRows)
  }

  var routeShowLabelsInRowsBinding: Binding<Bool> {
    routePreferencesToggleBinding(\.showLabelsInRows)
  }

  var routeShowLineCountersInRowsBinding: Binding<Bool> {
    routePreferencesToggleBinding(\.showLineCountersInRows)
  }

  var routeShowPullRequestNumberInRowsBinding: Binding<Bool> {
    routePreferencesToggleBinding(\.showPullRequestNumberInRows)
  }

  var routeShowPullRequestAgeInRowsBinding: Binding<Bool> {
    routePreferencesToggleBinding(\.showPullRequestAgeInRows)
  }

  var routeWrapTitlesInRowsBinding: Binding<Bool> {
    routePreferencesToggleBinding(\.wrapTitlesInRows)
  }

  var routeSemanticPrefixesBinding: Binding<Bool> {
    routePreferencesToggleBinding(\.hideSemanticPrefixesInRowTitles)
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

  var routeReviewPolicyPreviewByPullRequestID: [String: ReviewsPolicyPreviewResponse] {
    get { routeStateStorage.actionState.policyPreviewByPullRequestID }
    nonmutating set { routeStateStorage.actionState.policyPreviewByPullRequestID = newValue }
  }

  var routeReviewPolicyStatusByPullRequestID: [String: ReviewsPolicyStatusResponse] {
    get { routeStateStorage.actionState.policyStatusByPullRequestID }
    nonmutating set { routeStateStorage.actionState.policyStatusByPullRequestID = newValue }
  }

  var routePinnedPullRequests: DashboardReviewsPinnedPullRequests {
    get { routeStateStorage.pinnedPullRequests }
    nonmutating set { routeStateStorage.pinnedPullRequests = newValue }
  }

  var routeSnoozedPullRequests: DashboardReviewsSnoozedPullRequests {
    get { routeStateStorage.snoozedPullRequests }
    nonmutating set { routeStateStorage.snoozedPullRequests = newValue }
  }

  var routePinnedRepositories: DashboardReviewsPinnedRepositories {
    get { routeStateStorage.pinnedRepositories }
    nonmutating set { routeStateStorage.pinnedRepositories = newValue }
  }

  var routePendingActionConfirmation: DashboardReviewActionConfirmation? {
    get { routeStateStorage.actionState.pendingConfirmation }
    nonmutating set { routeStateStorage.actionState.pendingConfirmation = newValue }
  }

  var routePastedTextReviewSheet: DashboardReviewsPastedTextReviewSheetState? {
    get { routeStateStorage.actionState.pastedTextReviewSheet }
    nonmutating set { routeStateStorage.actionState.pastedTextReviewSheet = newValue }
  }

  var routeHandledScreenshotPasteboardRequestID: Int {
    get { routeStateStorage.actionState.handledScreenshotPasteboardRequestID }
    nonmutating set { routeStateStorage.actionState.handledScreenshotPasteboardRequestID = newValue }
  }

  var routePastedTextReviewSheetBinding: Binding<DashboardReviewsPastedTextReviewSheetState?> {
    Binding(
      get: { routePastedTextReviewSheet },
      set: { routePastedTextReviewSheet = $0 }
    )
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

  private func routePreferencesToggleBinding(
    _ keyPath: WritableKeyPath<DashboardReviewsPreferences, Bool>
  ) -> Binding<Bool> {
    Binding(
      get: { normalizedPreferences[keyPath: keyPath] },
      set: { newValue in
        var nextPreferences = DashboardReviewsPreferences.decode(from: storedPreferences)
        guard nextPreferences[keyPath: keyPath] != newValue else { return }
        nextPreferences[keyPath: keyPath] = newValue
        storedPreferences = nextPreferences.encodedString
      }
    )
  }
}
