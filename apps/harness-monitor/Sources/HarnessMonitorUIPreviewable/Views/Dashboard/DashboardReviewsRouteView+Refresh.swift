import HarnessMonitorKit
import SwiftUI

extension DashboardReviewsRouteView {
  func scheduleAffectedRefresh(
    for items: [ReviewItem],
    using client: any HarnessMonitorClientProtocol
  ) {
    guard !items.isEmpty else { return }
    let targetIDs = items.map(\.pullRequestID)
    let targets = items.map(\.target)
    beginRefreshing(pullRequestIDs: targetIDs)
    trackInFlight(
      Task {
        defer { endRefreshing(pullRequestIDs: targetIDs) }
        do {
          let refreshed = try await DashboardReviewsTimeoutRacer.race(
            timeoutSeconds: DashboardReviewsTimeoutRacer.defaultRefreshTimeoutSeconds
          ) {
            try await DashboardReviewsRemoteLoader.refresh(
              client: client,
              request: ReviewsRefreshRequest(
                targets: targets,
                backportDetectionEnabled: normalizedPreferences.backportDetectionEnabled,
                backportPatterns: normalizedPreferences.normalizedBackportPatterns
              )
            )
          }
          applyRefreshedItems(refreshed)
        } catch let error as DashboardReviewsSchedulerError {
          HarnessMonitorLogger.api.warning(
            """
            Review targeted refresh timed out: \
            targets=\(targetIDs.count, privacy: .public) \
            error=\(String(reflecting: error), privacy: .public)
            """
          )
          presentRefreshTimeoutBanner(for: items)
        } catch {
          HarnessMonitorLogger.api.warning(
            "Review targeted refresh failed: \(String(reflecting: error), privacy: .public)"
          )
        }
      }
    )
  }

  /// Surfaces the dropped timeout as a transient banner the user can tap to
  /// re-enqueue the same refresh, plus an announcement toast for VoiceOver and
  /// users who have the toast layer in view. Without this, a timed-out refresh
  /// only emits a log line and disappears silently (item 52).
  func presentRefreshTimeoutBanner(for items: [ReviewItem]) {
    routeRefreshTimeoutItems = items
    store.toast.presentWarning(
      "Refresh for \(items.count) pull request\(items.count == 1 ? "" : "s") timed out",
      accessibilityIdentifier:
        HarnessMonitorAccessibility.dashboardReviewsRefreshTimeoutToast
    )
  }

  /// Re-enqueues the most recent timed-out refresh. Clears the banner state
  /// before scheduling so a rapid double-tap doesn't stack two banners on the
  /// same items.
  func retryRefreshTimeout() {
    guard let pending = routeRefreshTimeoutItems else { return }
    routeRefreshTimeoutItems = nil
    guard let client = store.apiClient else { return }
    scheduleAffectedRefresh(for: pending, using: client)
  }

  /// Test seam: invoke the timeout catch branch directly. Production code goes
  /// through `scheduleAffectedRefresh`'s catch block; the test version skips
  /// the network path so the banner-state contract can be asserted without a
  /// stubbed timeout race.
  func handleRefreshTimeoutForTesting(items: [ReviewItem]) {
    presentRefreshTimeoutBanner(for: items)
  }

  func isPullRequestRefreshing(_ pullRequestID: String) -> Bool {
    routeRefreshTracker.isRefreshing(pullRequestID)
  }

  func pullRequestActionTitle(_ pullRequestID: String) -> String? {
    routeRefreshTracker.actionTitle(for: pullRequestID)
  }

  func beginRefreshing(pullRequestIDs ids: [String], actionTitle title: String? = nil) {
    var tracker = routeRefreshTracker
    tracker.begin(pullRequestIDs: ids, actionTitle: title)
    withAnimation(.easeInOut(duration: 0.18)) {
      routeRefreshTracker = tracker
    }
  }

  func endRefreshing(pullRequestIDs ids: [String]) {
    var tracker = routeRefreshTracker
    tracker.end(pullRequestIDs: ids)
    withAnimation(.easeInOut(duration: 0.18)) {
      routeRefreshTracker = tracker
    }
  }

  func pruneRefreshTrackerToLiveItems() {
    let liveIDs = Set(routeResponse.items.map(\.pullRequestID))
    var tracker = routeRefreshTracker
    tracker.prune(toLiveIDs: liveIDs)
    routeRefreshTracker = tracker
  }

  func applyRefreshedItems(_ refresh: ReviewsRefreshResponse) {
    let normalizedRefresh = HarnessMonitorReviewsDaemonNormalizer.normalize(
      refresh: refresh,
      daemonWireVersion: store.health?.wireVersion
    )
    let currentResponse = routeResponse
    let nextItems = applyReviewsRefresh(to: currentResponse.items, refresh: normalizedRefresh)
    let response = ReviewsQueryResponse(
      fetchedAt: normalizedRefresh.fetchedAt,
      fromCache: currentResponse.fromCache,
      summary: ReviewsSummary(items: nextItems),
      items: nextItems,
      repositoryLabels: currentResponse.repositoryLabels,
      viewerLogin: currentResponse.viewerLogin
    )
    let itemsChanged = nextItems != currentResponse.items
    setRouteResponse(response, bumpsItemsRevision: itemsChanged)
    pruneRefreshTrackerToLiveItems()
    persistReviewsRefresh(normalizedRefresh)
    // Invalidate only timelines whose detail pane is currently subscribed.
    // Without this guard, every targeted refresh clears the cached timeline
    // for PRs nobody is looking at, forcing a fresh fetch on the next visit
    // (item 53). Uses normalizedRefresh.items so the back-compat shim's
    // viewerCanUpdate fill-in is honoured before any subscriber lookup.
    let subscribed = normalizedRefresh.items
      .map(\.pullRequestID)
      .filter { store.activeTimelineSubscriptions.contains($0) }
    if !subscribed.isEmpty {
      store.invalidateReviewTimelines(for: subscribed)
    }
  }
}
