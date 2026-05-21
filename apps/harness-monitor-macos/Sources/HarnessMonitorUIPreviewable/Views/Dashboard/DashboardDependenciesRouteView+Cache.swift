import HarnessMonitorKit
import SwiftUI

extension DashboardDependenciesRouteView {
  var dependenciesCache: DependencyUpdatesCache? {
    guard let context = store.modelContext else { return nil }
    return DependencyUpdatesCache(context: context)
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
    guard response.items.isEmpty,
      let cache = dependenciesCache,
      let cached = cache.load(preferencesHash: dependenciesCachePreferencesHash)
    else {
      return false
    }
    response = cached
    reconcileSelection()
    return true
  }

  func persistDependenciesResponse(_ response: DependencyUpdatesQueryResponse) {
    dependenciesCache?.save(
      preferencesHash: dependenciesCachePreferencesHash,
      response: response
    )
  }

  func persistDependenciesRefresh(_ refresh: DependencyUpdatesRefreshResponse) {
    dependenciesCache?.applyRefresh(
      preferencesHash: dependenciesCachePreferencesHash,
      refresh: refresh
    )
  }
}
