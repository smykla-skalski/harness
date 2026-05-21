import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard dependencies presentation worker")
struct DashboardDependenciesPresentationWorkerTests {
  @Test("filters, groups, and selects dependency update rows off main")
  func filtersGroupsAndSelectsDependencyRows() async {
    let first = dependencyItem(
      id: "pr-1",
      repository: "kong/a",
      number: 1,
      title: "Renovate minor update",
      reviewStatus: .approved,
      checkStatus: .success,
      createdAt: "2026-05-01T10:00:00Z"
    )
    let second = dependencyItem(
      id: "pr-2",
      repository: "kong/b",
      number: 2,
      title: "Renovate security update",
      reviewStatus: .reviewRequired,
      checkStatus: .success,
      createdAt: "2026-05-02T10:00:00Z"
    )
    let third = dependencyItem(
      id: "pr-3",
      repository: "kumahq/kuma",
      number: 3,
      title: "Bot update",
      authorLogin: "renovate[bot]",
      reviewStatus: .none,
      checkStatus: .pending,
      createdAt: "2026-05-03T10:00:00Z"
    )

    let worker = DashboardDependenciesPresentationWorker()
    let output = await worker.compute(
      input: DashboardDependenciesPresentationInput(
        items: [third, second, first],
        filterModeRaw: DashboardDependenciesFilterMode.review.rawValue,
        sortModeRaw: DashboardDependenciesSortMode.repository.rawValue,
        searchText: "security",
        configuredRepositories: ["kong/b", "kong/a"],
        configuredOrganizations: ["kumahq"],
        selectedIDs: [second.pullRequestID],
        persistedPrimarySelectionID: ""
      )
    )

    #expect(output.filteredItems.map(\.pullRequestID) == ["pr-2"])
    #expect(output.groupedItems.map(\.repository) == ["kong/b"])
    #expect(output.selectedItems.map(\.pullRequestID) == ["pr-2"])
    #expect(output.primaryDetailItem?.pullRequestID == "pr-2")
    #expect(output.relativeUpdatedLabels["pr-2"] != nil)
  }

  @Test("uses configured repository order and persisted primary selection")
  func usesConfiguredRepositoryOrderAndPersistedSelection() async {
    let first = dependencyItem(id: "pr-1", repository: "kong/a", number: 1)
    let second = dependencyItem(id: "pr-2", repository: "kong/b", number: 2)
    let third = dependencyItem(id: "pr-3", repository: "kumahq/kuma", number: 3)

    let output = await DashboardDependenciesPresentationWorker().compute(
      input: DashboardDependenciesPresentationInput(
        items: [first, second, third],
        filterModeRaw: DashboardDependenciesFilterMode.all.rawValue,
        sortModeRaw: DashboardDependenciesSortMode.repository.rawValue,
        searchText: "",
        configuredRepositories: ["kong/b", "kong/a"],
        configuredOrganizations: ["kumahq"],
        selectedIDs: [],
        persistedPrimarySelectionID: third.pullRequestID
      )
    )

    #expect(output.groupedItems.map(\.repository) == ["kong/b", "kong/a", "kumahq/kuma"])
    #expect(output.primaryDetailItem?.pullRequestID == "pr-3")
  }

  @Test("precomputes row relative date labels with fallback for bad timestamps")
  func precomputesRowRelativeDateLabelsWithFallback() async {
    let item = dependencyItem(
      id: "pr-invalid",
      repository: "kong/a",
      number: 1,
      updatedAt: "not-a-date"
    )

    let output = await DashboardDependenciesPresentationWorker().compute(
      input: DashboardDependenciesPresentationInput(
        items: [item],
        filterModeRaw: DashboardDependenciesFilterMode.all.rawValue,
        sortModeRaw: DashboardDependenciesSortMode.repository.rawValue,
        searchText: "",
        configuredRepositories: [],
        configuredOrganizations: [],
        selectedIDs: [],
        persistedPrimarySelectionID: ""
      )
    )

    #expect(output.relativeUpdatedLabels["pr-invalid"] == "not-a-date")
  }

  private func dependencyItem(
    id: String,
    repository: String,
    number: UInt64,
    title: String = "Dependency update",
    authorLogin: String = "renovate[bot]",
    reviewStatus: DependencyUpdateReviewStatus = .none,
    checkStatus: DependencyUpdateCheckStatus = .success,
    createdAt: String = "2026-05-01T10:00:00Z",
    updatedAt: String? = nil
  ) -> DependencyUpdateItem {
    DependencyUpdateItem(
      pullRequestID: id,
      repositoryID: "repo-\(repository)",
      repository: repository,
      number: number,
      title: title,
      url: "https://github.com/\(repository)/pull/\(number)",
      authorLogin: authorLogin,
      state: .open,
      mergeable: .mergeable,
      reviewStatus: reviewStatus,
      checkStatus: checkStatus,
      policyBlocked: false,
      isDraft: false,
      headSha: "sha-\(id)",
      labels: ["dependencies"],
      additions: 1,
      deletions: 1,
      createdAt: createdAt,
      updatedAt: updatedAt ?? createdAt
    )
  }
}
