import HarnessMonitorKit

extension DashboardDependenciesRouteView {
  func refreshLabelMenuData() {
    let limit = normalizedPreferences.frequentLabelsCount
    let usageCache = repositoryLabelUsageCache
    var result: [String: DashboardDependenciesRepoLabelMenuData] = [:]
    result.reserveCapacity(routeResponse.repositoryLabels.count)
    for (repository, labels) in routeResponse.repositoryLabels {
      let sorted = labels.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
      let frequent = usageCache?.topUsed(repositories: [repository], limit: limit) ?? []
      result[repository] = DashboardDependenciesRepoLabelMenuData(
        sortedLabels: sorted,
        frequentNames: frequent
      )
    }
    guard result != routeLabelMenuDataByRepository else { return }
    routeLabelMenuDataByRepository = result
  }

  func rowAvailableLabels(for item: DependencyUpdateItem) -> [DependencyUpdateRepositoryLabel] {
    guard let data = routeLabelMenuDataByRepository[item.repository] else { return [] }
    let applied = Set(item.labels)
    return data.sortedLabels.filter { !applied.contains($0.name) }
  }

  func rowFrequentLabelNames(for item: DependencyUpdateItem) -> [String] {
    routeLabelMenuDataByRepository[item.repository]?.frequentNames ?? []
  }

  func syncCollapsedRepositoriesFromStorage(_ storedValue: String) {
    let next = DashboardDependenciesCollapsedRepositories.decode(from: storedValue)
    guard next != routeCollapsedRepositories else { return }
    routeCollapsedRepositories = next
  }

  func syncPreferencesFromStorage(_ storedValue: String) {
    let nextPreferences = DashboardDependenciesResolvedPreferences(storedValue: storedValue)
    guard nextPreferences != routeResolvedPreferences else { return }
    routeResolvedPreferences = nextPreferences
  }
}
