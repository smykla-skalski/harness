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

  func syncPreferencesFromStorage(_ storedValue: String) {
    let nextPreferences = DashboardReviewsResolvedPreferences(storedValue: storedValue)
    guard nextPreferences != routeResolvedPreferences else { return }
    routeResolvedPreferences = nextPreferences
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
