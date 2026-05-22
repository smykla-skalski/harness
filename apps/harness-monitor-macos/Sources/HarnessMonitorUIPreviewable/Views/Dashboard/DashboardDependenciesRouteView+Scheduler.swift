import HarnessMonitorKit
import SwiftUI

extension DashboardDependenciesRouteView {
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
      let repositories = try await resolver.resolveRepositories(
        explicitRepositories: preferences.repositories,
        organizations: preferences.organizations,
        excludeRepositories: preferences.excludeRepositories,
        expandOrganizations: preferences.preferences.expandOrganizations
      )
      guard !Task.isCancelled else { return }
      let hydrated =
        repoSyncStateCache?
        .loadStates(preferencesHash: dependenciesCachePreferencesHash) ?? [:]
      routeScheduler.start(
        repositories: repositories,
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
        Dependency repository resolution failed; \
        error=\(String(reflecting: error), privacy: .public)
        """
      )
      let displayMessage = dashboardDependenciesErrorMessage(for: error)
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

  func retryRepositorySync(_ repository: String) {
    Task {
      await routeScheduler.retry(repository: repository)
    }
  }

  func retryRepositories(_ repositories: [String]) {
    guard !repositories.isEmpty else { return }
    Task {
      for repository in repositories {
        await routeScheduler.retry(repository: repository)
      }
    }
  }

  var routeSyncHealth: DashboardDependenciesSyncHealth {
    DashboardDependenciesSyncHealth.snapshot(
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
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDependenciesSchedulerBadge)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Syncing \(inFlight) of \(total) repositories")
  }

  // MARK: - Internal helpers

  func applyPerRepoResponse(
    repository: String,
    response perResponse: DependencyUpdatesQueryResponse
  ) {
    let nextItems = DependencyUpdatesCache.applyPerRepoResponseToItems(
      routeResponse.items,
      repository: repository,
      response: perResponse
    )
    var mergedLabels = routeResponse.repositoryLabels
    if let updatedLabels = perResponse.repositoryLabels[repository],
      !updatedLabels.isEmpty
    {
      mergedLabels[repository] = updatedLabels
    }
    let needsCacheBackfill = mergedLabels[repository, default: []].isEmpty
    routeResponse = DependencyUpdatesQueryResponse(
      fetchedAt: perResponse.fetchedAt,
      fromCache: false,
      summary: DependencyUpdatesSummary(items: nextItems),
      items: nextItems,
      repositoryLabels: mergedLabels
    )
    if needsCacheBackfill {
      hydrateRepositoryLabelsFromCache()
    }
    pruneRefreshTrackerToLiveItems()
    routeErrorMessage = nil
    reconcileSelection()
    persistDependenciesPerRepoResponse(
      repository: repository,
      response: perResponse,
      fallbackResponse: routeResponse
    )
  }

  func ensureRepoResolver(
    client: any HarnessMonitorClientProtocol
  ) -> DashboardDependenciesRepoResolver {
    DashboardDependenciesRepoResolver(client: client)
  }
}
