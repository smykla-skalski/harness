import HarnessMonitorKit
import SwiftUI

extension DashboardDependenciesRouteView {
  var dependenciesCache: DependencyUpdatesCache? {
    guard let context = store.modelContext else { return nil }
    return DependencyUpdatesCache(context: context)
  }

  var repositoryLabelsCache: RepositoryLabelsCache? {
    guard let context = store.modelContext else { return nil }
    return RepositoryLabelsCache(context: context)
  }

  var repositoryLabelUsageCache: RepositoryLabelUsageCache? {
    guard let context = store.modelContext else { return nil }
    return RepositoryLabelUsageCache(context: context)
  }

  var repoSyncStateCache: DependencyUpdatesRepoSyncStateCache? {
    guard let context = store.modelContext else { return nil }
    return DependencyUpdatesRepoSyncStateCache(context: context)
  }

  var dependencyCachePersistenceWriter: DependencyUpdatesCachePersistenceWriter? {
    guard let modelContainer = store.modelContext?.container else { return nil }
    return DependencyUpdatesCachePersistenceWriter(modelContainer: modelContainer)
  }

  func frequentLabelNames(for items: [DependencyUpdateItem]) -> [String] {
    guard let cache = repositoryLabelUsageCache, !items.isEmpty else { return [] }
    let repositories = Array(Set(items.map(\.repository)))
    let limit = routeResolvedPreferences.preferences.frequentLabelsCount
    return cache.topUsed(repositories: repositories, limit: limit)
  }

  func recordLabelUsage(_ label: String, items: [DependencyUpdateItem]) {
    guard let cache = repositoryLabelUsageCache else { return }
    for item in items {
      cache.recordUse(repository: item.repository, label: label)
    }
    refreshLabelMenuData()
  }

  var dependenciesCachePreferencesHash: String {
    routeResolvedPreferences.cacheHash
  }

  /// Restore the last persisted response into `response` when the in-memory
  /// list is still empty. Returns whether a cached snapshot was applied.
  @discardableResult
  func hydrateDependenciesFromCacheIfNeeded() -> Bool {
    var didApply = false
    if routeResponse.items.isEmpty,
      let cache = dependenciesCache,
      let cached = cache.load(preferencesHash: dependenciesCachePreferencesHash)
    {
      routeResponse = cached
      reconcileSelection()
      didApply = true
    }
    hydrateRepositoryLabelsFromCache()
    return didApply
  }

  /// Merge cached per-repo labels into the current response so the label
  /// picker has access to every previously-seen project's labels, regardless
  /// of which preferences bucket the cached snapshot lived in or whether the
  /// daemon is reachable right now.
  func hydrateRepositoryLabelsFromCache() {
    guard let cache = repositoryLabelsCache else { return }
    let cached = cache.loadAll()
    guard !cached.isEmpty else { return }
    var merged = routeResponse.repositoryLabels
    for (repository, labels) in cached where merged[repository, default: []].isEmpty {
      merged[repository] = labels
    }
    if merged != routeResponse.repositoryLabels {
      routeResponse = DependencyUpdatesQueryResponse(
        fetchedAt: routeResponse.fetchedAt,
        fromCache: routeResponse.fromCache,
        summary: routeResponse.summary,
        items: routeResponse.items,
        repositoryLabels: merged
      )
    }
  }

  func persistDependenciesResponse(_ response: DependencyUpdatesQueryResponse) {
    guard let writer = dependencyCachePersistenceWriter else { return }
    let preferencesHash = dependenciesCachePreferencesHash
    Task {
      await writer.saveResponse(
        preferencesHash: preferencesHash,
        response: response
      )
    }
  }

  func persistDependenciesRefresh(_ refresh: DependencyUpdatesRefreshResponse) {
    guard let writer = dependencyCachePersistenceWriter else { return }
    let preferencesHash = dependenciesCachePreferencesHash
    Task {
      await writer.applyRefresh(
        preferencesHash: preferencesHash,
        refresh: refresh
      )
    }
  }

  func persistDependenciesPerRepoResponse(
    repository: String,
    response: DependencyUpdatesQueryResponse,
    fallbackResponse: DependencyUpdatesQueryResponse
  ) {
    guard let writer = dependencyCachePersistenceWriter else { return }
    let preferencesHash = dependenciesCachePreferencesHash
    Task {
      await writer.applyPerRepoResponse(
        preferencesHash: preferencesHash,
        repository: repository,
        response: response,
        fallbackResponse: fallbackResponse
      )
      await writer.recordRepoSyncedAt(
        preferencesHash: preferencesHash,
        repository: repository
      )
    }
  }
}
