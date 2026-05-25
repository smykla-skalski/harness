import HarnessMonitorKit

extension DashboardReviewsRouteView {
  func refreshLabelMenuData() {
    let limit = normalizedPreferences.frequentLabelsCount
    let usageCache = repositoryLabelUsageCache
    var result: [String: DashboardReviewsRepoLabelMenuData] = [:]
    result.reserveCapacity(routeResponse.repositoryLabels.count)
    for (repository, labels) in routeResponse.repositoryLabels {
      let sorted = labels.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
      let frequent = usageCache?.topUsed(repositories: [repository], limit: limit) ?? []
      result[repository] = DashboardReviewsRepoLabelMenuData(
        sortedLabels: sorted,
        frequentNames: frequent
      )
    }
    guard result != routeLabelMenuDataByRepository else { return }
    routeLabelMenuDataByRepository = result
  }

  func rowAvailableLabels(for item: ReviewItem) -> [ReviewRepositoryLabel] {
    guard let data = routeLabelMenuDataByRepository[item.repository] else { return [] }
    let applied = Set(item.labels)
    return data.sortedLabels.filter { !applied.contains($0.name) }
  }

  func rowFrequentLabelNames(for item: ReviewItem) -> [String] {
    routeLabelMenuDataByRepository[item.repository]?.frequentNames ?? []
  }

  func syncCollapsedRepositoriesFromStorage(_ storedValue: String) {
    let next = DashboardReviewsCollapsedRepositories.decode(from: storedValue)
    guard next != routeCollapsedRepositories else { return }
    routeCollapsedRepositories = next
  }

  func syncPinnedPullRequestsFromStorage(_ storedValue: String) {
    let next = DashboardReviewsPinnedPullRequests.decode(from: storedValue)
    guard next != routePinnedPullRequests else { return }
    routePinnedPullRequests = next
  }

  func syncPreferencesFromStorage(_ storedValue: String) {
    // Why: `.onChange(of: storedPreferences)` fires with `initial: true` and
    // re-fires on every UserDefaults write the surface emits. Hash the raw
    // stored string first and skip the JSON decode + Equatable comparison
    // when the input is byte-identical to the last value we synced.
    let storedValueHash = storedValue.hashValue
    let decision = dashboardReviewsResolvedPreferencesCacheDecision(
      lastHash: routeLastStoredPreferencesHash,
      nextHash: storedValueHash
    )
    if decision == .skipDecode { return }
    routeLastStoredPreferencesHash = storedValueHash
    let nextPreferences = DashboardReviewsResolvedPreferences(storedValue: storedValue)
    routeReviewsPreferencesStore.replace(nextPreferences.preferences)
    guard nextPreferences != routeResolvedPreferences else { return }
    routeResolvedPreferences = nextPreferences
  }
}

// The hash-gated decode skip decision is pulled out as a free helper so unit
// tests can drive the decision table without standing up a SwiftUI route view.
// `nextHash` is the cheap fingerprint of the raw stored string; matching the
// `lastHash` lets the caller skip the JSON decode entirely.
enum DashboardReviewsResolvedPreferencesCacheDecision: Equatable {
  case skipDecode
  case decode
}

func dashboardReviewsResolvedPreferencesCacheDecision(
  lastHash: Int?,
  nextHash: Int
) -> DashboardReviewsResolvedPreferencesCacheDecision {
  if lastHash == nextHash {
    return .skipDecode
  }
  return .decode
}

extension DashboardReviewsRouteView {

  // Returns the count of items that require attention from the viewer. Hoisted
  // off the SwiftUI body path so the Needs-Me badge does not recompute on every
  // body re-render of `DashboardReviewsControlStrip`. Marked `nonisolated` so
  // unit tests in a non-MainActor context can drive the contract without
  // needing the surrounding actor hop.
  nonisolated static func recomputeNeedsMeCount(items: [ReviewItem]) -> Int {
    items.lazy.filter(\.requiresAttention).count
  }

  func prefetchSelectedBodies(adding newlySelected: Set<String>) {
    guard !newlySelected.isEmpty else { return }
    let itemsByID = Dictionary(
      routeResponse.items.map { ($0.pullRequestID, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    for id in newlySelected {
      guard let item = itemsByID[id] else { continue }
      Task { await store.prepareReviewBody(for: item) }
    }
  }
}
