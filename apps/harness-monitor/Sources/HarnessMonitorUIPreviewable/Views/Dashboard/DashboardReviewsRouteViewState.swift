import HarnessMonitorKit
import Observation
import SwiftUI

/// Mutable runtime state for DashboardReviewsRouteView. Held as
/// `@State private var routeState` so all @State properties satisfy
/// `private_swiftui_state` while remaining accessible across the
/// +Accessors.swift companion extension via the shared class reference.
@Observable
@MainActor
final class DashboardReviewsRouteViewState {
  var response = ReviewsQueryResponse(
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
  var responseItemsRevision: UInt64 = 0
  var isLoading = false
  var isBackgroundRefreshing = false
  var errorMessage: String?
  var selectedIDs = Set<String>()
  var isLabelSheetPresented = false
  var labelDraft = ""
  var labelTargetItems = [ReviewItem]()
  var resolvedPreferences: DashboardReviewsResolvedPreferences
  var presentationWorker = DashboardReviewsPresentationWorker()
  var cachedPresentation = DashboardReviewsPresentation.empty
  var presentationGeneration: UInt64 = 0
  var refreshTracker = ReviewRefreshTracker()
  var inFlightTasks: [Task<Void, Never>] = []
  /// Items whose most recent targeted refresh timed out.
  var refreshTimeoutItems: [ReviewItem]?
  /// Tracks items that disappeared between response diffs.
  var disappearedTracker = DashboardReviewsDisappearedItemTracker()
  /// Descriptors emitted by the most recent disappeared-item diff.
  var disappearedDescriptors: [DashboardReviewsDisappearedItemTracker.Descriptor] = []
  var scheduler = DashboardReviewsScheduler()
  var collapsedRepositories = DashboardReviewsCollapsedRepositories()
  var labelMenuDataByRepository: [String: DashboardReviewsRepoLabelMenuData] = [:]
  var actionState = DashboardReviewsRouteActionState()
  var legacyFilterMigrationApplied = false
  var lastPrimaryClickedID: String?
  var isReviewsRouteActive = true
  var pendingResumeAfterReturn = false
  var handledDashboardHistoryRestoreRequestID = 0
  var lastStoredPreferencesHash: Int?
  var needsMeCount: Int = 0
  var pinnedPullRequests: DashboardReviewsPinnedPullRequests
  var pinnedRepositories: DashboardReviewsPinnedRepositories

  init(
    resolvedPreferences: DashboardReviewsResolvedPreferences,
    pinnedPullRequests: DashboardReviewsPinnedPullRequests,
    pinnedRepositories: DashboardReviewsPinnedRepositories
  ) {
    self.resolvedPreferences = resolvedPreferences
    self.pinnedPullRequests = pinnedPullRequests
    self.pinnedRepositories = pinnedRepositories
  }
}
