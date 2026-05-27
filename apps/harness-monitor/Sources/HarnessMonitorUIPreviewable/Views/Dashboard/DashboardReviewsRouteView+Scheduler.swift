import HarnessMonitorKit
import SwiftUI

extension DashboardReviewsRouteView {
  /// Resolve the repository list from preferences and (re)start the
  /// per-repository scheduler. Idempotent and safe to call on every
  /// preferences-change tick; the scheduler internally cancels its prior
  /// tick task and any in-flight fetches before resuming.
  func startScheduler(forceRefreshAll: Bool = false) async {
    guard let client = store.apiClient else {
      routeScheduler.stop()
      return
    }
    let preferences = routeResolvedPreferences
    let resolver = ensureRepoResolver(client: client)
    do {
      let resolvedRepositories = try await resolver.resolveRepositories(
        explicitRepositories: preferences.repositories,
        organizations: preferences.organizations,
        excludeRepositories: preferences.excludeRepositories,
        expandOrganizations: preferences.preferences.expandOrganizations
      )
      guard !Task.isCancelled else { return }
      let trackedRepositories = dashboardReviewsTrackedRepositories(
        resolvedRepositories: resolvedRepositories,
        visibleRepositories: routeResponse.items.map(\.repository),
        excludeRepositories: preferences.excludeRepositories
      )
      let hydratedStates =
        repoSyncStateCache?
        .loadStates(preferencesHash: reviewsCachePreferencesHash) ?? [:]
      let hydrated = Dictionary(
        uniqueKeysWithValues: trackedRepositories.compactMap { repository in
          dashboardReviewsHydratedLastSyncedAt(
            repository: repository,
            hydratedStates: hydratedStates
          ).map { (repository, $0) }
        }
      )
      routeScheduler.start(
        repositories: trackedRepositories,
        preferences: preferences,
        client: client,
        initialLastSyncedAt: hydrated,
        forceRefreshAll: forceRefreshAll,
        onMerge: { [self] repository, response in
          self.applyPerRepoResponse(repository: repository, response: response)
        }
      )
    } catch {
      HarnessMonitorLogger.api.warning(
        """
        Reviews repository resolution failed; \
        error=\(String(reflecting: error), privacy: .public)
        """
      )
      let displayMessage = dashboardReviewsErrorMessage(for: error)
      if routeResponse.items.isEmpty {
        routeErrorMessage = displayMessage
      } else {
        store.presentFailureFeedback(displayMessage)
      }
    }
  }

  /// Mark a single repository for refresh on the next tick. Called from
  /// `scheduleAffectedRefresh` after a per-PR mutation when the targeted
  /// refresh path is not granular enough.
  func schedulerForceRefresh(repository: String) {
    routeScheduler.forceRefresh(repository: repository)
  }

  func syncRepository(_ repository: String) {
    Task {
      let hydratedStates =
        repoSyncStateCache?
        .loadStates(preferencesHash: reviewsCachePreferencesHash) ?? [:]
      let tracked = routeScheduler.ensureTracked(
        repository: repository,
        lastSyncedAt: dashboardReviewsHydratedLastSyncedAt(
          repository: repository,
          hydratedStates: hydratedStates
        )
      )
      await routeScheduler.retry(repository: tracked)
    }
  }

  func retryRepositories(_ repositories: [String]) {
    guard !repositories.isEmpty else { return }
    Task {
      for repository in repositories {
        let tracked = routeScheduler.ensureTracked(repository: repository)
        await routeScheduler.retry(repository: tracked)
      }
    }
  }

  func trackVisibleRepositories(_ items: [ReviewItem]) {
    let excludedKeys = Set(
      routeResolvedPreferences.excludeRepositories.map(dashboardReviewsRepositoryTrackingKey)
    )
    let visibleRepositories =
      items
      .map(\.repository)
      .filter {
        let key = dashboardReviewsRepositoryTrackingKey($0)
        return !key.isEmpty && !excludedKeys.contains(key)
      }
      .filter { routeScheduler.syncState(for: $0) == nil }
    guard !visibleRepositories.isEmpty else { return }

    let hydratedStates =
      repoSyncStateCache?
      .loadStates(preferencesHash: reviewsCachePreferencesHash) ?? [:]
    for repository in visibleRepositories {
      _ = routeScheduler.ensureTracked(
        repository: repository,
        lastSyncedAt: dashboardReviewsHydratedLastSyncedAt(
          repository: repository,
          hydratedStates: hydratedStates
        )
      )
    }
  }

  var routeSyncHealth: DashboardReviewsSyncHealth {
    DashboardReviewsSyncHealth.snapshot(
      scheduler: routeScheduler,
      staleAfterSeconds: TimeInterval(normalizedPreferences.perRepositoryIntervalSeconds)
    )
  }

  /// True while any tracked repository is currently being fetched.
  var isAnyRepositorySyncing: Bool {
    !routeScheduler.repositoriesInFlight.isEmpty
  }

  /// Snapshot of currently in-flight repositories for per-section progress
  /// indicators.
  var refreshingRepositories: Set<String> {
    routeScheduler.repositoriesInFlight
  }

  /// Compact "Syncing N of M" indicator shown in the summary card while the
  /// scheduler has any repository in flight.
  @ViewBuilder var schedulerProgressBadge: some View {
    let total = max(routeScheduler.states.count, 1)
    let inFlight = routeScheduler.repositoriesInFlight.count
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      ProgressView()
        .controlSize(.small)
      Text("Syncing \(inFlight) of \(total)")
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsSchedulerBadge)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Syncing \(inFlight) of \(total) repositories")
  }

  // MARK: - Internal helpers

  func applyPerRepoResponse(
    repository: String,
    response perResponse: ReviewsQueryResponse
  ) {
    let normalizedPerResponse = HarnessMonitorReviewsDaemonNormalizer.normalize(
      response: perResponse,
      daemonWireVersion: store.health?.wireVersion
    )
    let currentResponse = routeResponse
    let nextItems = ReviewsCache.applyPerRepoResponseToItems(
      currentResponse.items,
      repository: repository,
      response: normalizedPerResponse
    )
    var mergedLabels = currentResponse.repositoryLabels
    if let updatedLabels = normalizedPerResponse.repositoryLabels[repository],
      !updatedLabels.isEmpty
    {
      mergedLabels[repository] = updatedLabels
    }
    let needsCacheBackfill = mergedLabels[repository, default: []].isEmpty
    let response = ReviewsQueryResponse(
      fetchedAt: normalizedPerResponse.fetchedAt,
      fromCache: false,
      summary: ReviewsSummary(items: nextItems),
      items: nextItems,
      repositoryLabels: mergedLabels,
      viewerLogin: currentResponse.viewerLogin
    )
    let itemsChanged = nextItems != currentResponse.items
    setRouteResponse(response, bumpsItemsRevision: itemsChanged)
    if needsCacheBackfill {
      hydrateRepositoryLabelsFromCache()
    }
    pruneRefreshTrackerToLiveItems()
    routeErrorMessage = nil
    reconcileSelection()
    persistReviewsPerRepoResponse(
      repository: repository,
      response: normalizedPerResponse,
      fallbackResponse: routeResponse
    )
  }

  func ensureRepoResolver(
    client: any HarnessMonitorClientProtocol
  ) -> DashboardReviewsRepoResolver {
    DashboardReviewsRepoResolver(client: client)
  }
}
