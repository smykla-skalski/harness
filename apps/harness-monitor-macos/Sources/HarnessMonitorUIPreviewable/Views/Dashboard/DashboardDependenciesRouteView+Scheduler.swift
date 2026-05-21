import HarnessMonitorKit
import SwiftUI

extension DashboardDependenciesRouteView {
  /// Resolve the repository list from preferences and (re)start the
  /// per-repository scheduler. Idempotent and safe to call on every
  /// preferences-change tick; the scheduler internally cancels its prior
  /// tick task and any in-flight fetches before resuming.
  func startScheduler(forceRefreshAll: Bool = false) async {
    guard let client = store.apiClient else {
      scheduler.stop()
      return
    }
    let preferences = resolvedPreferences
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
      scheduler.start(
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
      if response.items.isEmpty {
        errorMessage = displayMessage
      } else {
        store.presentFailureFeedback(displayMessage)
      }
    }
  }

  /// Mark every tracked repository for refresh on the next tick. Called from
  /// the manual force-refresh button and after a daemon cache clear.
  func schedulerForceRefreshAll() {
    scheduler.forceRefreshAll()
  }

  /// Mark a single repository for refresh on the next tick. Called from
  /// `scheduleAffectedRefresh` after a per-PR mutation when the targeted
  /// refresh path is not granular enough.
  func schedulerForceRefresh(repository: String) {
    scheduler.forceRefresh(repository: repository)
  }

  /// True while any tracked repository is currently being fetched.
  var isAnyRepositorySyncing: Bool {
    !scheduler.repositoriesInFlight.isEmpty
  }

  /// Snapshot of currently in-flight repositories for per-section progress
  /// indicators.
  var refreshingRepositories: Set<String> {
    scheduler.repositoriesInFlight
  }

  /// Compact "Syncing N of M" indicator shown in the summary card while the
  /// scheduler has any repository in flight.
  @ViewBuilder var schedulerProgressBadge: some View {
    let total = max(scheduler.states.count, 1)
    let inFlight = scheduler.repositoriesInFlight.count
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

  private func applyPerRepoResponse(
    repository: String,
    response perResponse: DependencyUpdatesQueryResponse
  ) {
    let nextItems = DependencyUpdatesCache.applyPerRepoResponseToItems(
      response.items,
      repository: repository,
      response: perResponse
    )
    var mergedLabels = response.repositoryLabels
    if let updatedLabels = perResponse.repositoryLabels[repository] {
      mergedLabels[repository] = updatedLabels
    }
    response = DependencyUpdatesQueryResponse(
      fetchedAt: perResponse.fetchedAt,
      fromCache: false,
      summary: DependencyUpdatesSummary(items: nextItems),
      items: nextItems,
      repositoryLabels: mergedLabels
    )
    errorMessage = nil
    reconcileSelection()
    persistDependenciesPerRepoResponse(
      repository: repository,
      response: perResponse,
      fallbackResponse: response
    )
  }

  private func ensureRepoResolver(
    client: any HarnessMonitorClientProtocol
  ) -> DashboardDependenciesRepoResolver {
    DashboardDependenciesRepoResolver(client: client)
  }
}
