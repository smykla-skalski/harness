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

  var dependenciesCachePreferencesHash: String {
    DependencyUpdatesCache.preferencesHash(
      for: normalizedPreferences.queryRequest(forceRefresh: false)
    )
  }

  /// Restore the last persisted response into `response` when the in-memory
  /// list is still empty. Returns whether a cached snapshot was applied.
  @discardableResult
  func hydrateDependenciesFromCacheIfNeeded() -> Bool {
    var didApply = false
    if response.items.isEmpty,
      let cache = dependenciesCache,
      let cached = cache.load(preferencesHash: dependenciesCachePreferencesHash)
    {
      response = cached
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
    var merged = response.repositoryLabels
    for (repository, labels) in cached where merged[repository, default: []].isEmpty {
      merged[repository] = labels
    }
    if merged != response.repositoryLabels {
      response = DependencyUpdatesQueryResponse(
        fetchedAt: response.fetchedAt,
        fromCache: response.fromCache,
        summary: response.summary,
        items: response.items,
        repositoryLabels: merged
      )
    }
  }

  func persistDependenciesResponse(_ response: DependencyUpdatesQueryResponse) {
    dependenciesCache?.save(
      preferencesHash: dependenciesCachePreferencesHash,
      response: response
    )
    repositoryLabelsCache?.upsert(response.repositoryLabels)
  }

  func persistDependenciesRefresh(_ refresh: DependencyUpdatesRefreshResponse) {
    dependenciesCache?.applyRefresh(
      preferencesHash: dependenciesCachePreferencesHash,
      refresh: refresh
    )
  }
}
