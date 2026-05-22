import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard reviews presentation worker")
struct DashboardReviewsPresentationWorkerTests {
  @Test("filters, groups, and selects review rows off main")
  func filtersGroupsAndSelectsReviewRows() async {
    let first = reviewItem(
      id: "pr-1",
      repository: "kong/a",
      number: 1,
      title: "Renovate minor update",
      reviewStatus: .approved,
      checkStatus: .success,
      createdAt: "2026-05-01T10:00:00Z"
    )
    let second = reviewItem(
      id: "pr-2",
      repository: "kong/b",
      number: 2,
      title: "Renovate security update",
      reviewStatus: .reviewRequired,
      checkStatus: .success,
      createdAt: "2026-05-02T10:00:00Z"
    )
    let third = reviewItem(
      id: "pr-3",
      repository: "kumahq/kuma",
      number: 3,
      title: "Bot update",
      authorLogin: "renovate[bot]",
      reviewStatus: .none,
      checkStatus: .pending,
      createdAt: "2026-05-03T10:00:00Z"
    )

    let worker = DashboardReviewsPresentationWorker()
    let output = await worker.compute(
      input: DashboardReviewsPresentationInput(
        items: [third, second, first],
        filterModeRaw: DashboardReviewsFilterMode.review.rawValue,
        sortModeRaw: DashboardReviewsSortMode.repository.rawValue,
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
    let first = reviewItem(id: "pr-1", repository: "kong/a", number: 1)
    let second = reviewItem(id: "pr-2", repository: "kong/b", number: 2)
    let third = reviewItem(id: "pr-3", repository: "kumahq/kuma", number: 3)

    let output = await DashboardReviewsPresentationWorker().compute(
      input: DashboardReviewsPresentationInput(
        items: [first, second, third],
        filterModeRaw: DashboardReviewsFilterMode.all.rawValue,
        sortModeRaw: DashboardReviewsSortMode.repository.rawValue,
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
    let item = reviewItem(
      id: "pr-invalid",
      repository: "kong/a",
      number: 1,
      updatedAt: "not-a-date"
    )

    let output = await DashboardReviewsPresentationWorker().compute(
      input: DashboardReviewsPresentationInput(
        items: [item],
        filterModeRaw: DashboardReviewsFilterMode.all.rawValue,
        sortModeRaw: DashboardReviewsSortMode.repository.rawValue,
        searchText: "",
        configuredRepositories: [],
        configuredOrganizations: [],
        selectedIDs: [],
        persistedPrimarySelectionID: ""
      )
    )

    #expect(output.relativeUpdatedLabels["pr-invalid"] == "not-a-date")
  }

  @Test("precomputing row labels tolerates duplicate pull request ids")
  func precomputingRowLabelsToleratesDuplicatePullRequestIDs() async {
    let first = reviewItem(
      id: "pr-duplicate",
      repository: "kong/a",
      number: 1,
      updatedAt: "not-a-date"
    )
    let second = reviewItem(
      id: "pr-duplicate",
      repository: "kong/a",
      number: 2,
      updatedAt: "2026-05-01T10:00:00Z"
    )

    let output = await DashboardReviewsPresentationWorker().compute(
      input: DashboardReviewsPresentationInput(
        items: [first, second],
        filterModeRaw: DashboardReviewsFilterMode.all.rawValue,
        sortModeRaw: DashboardReviewsSortMode.repository.rawValue,
        searchText: "",
        configuredRepositories: [],
        configuredOrganizations: [],
        selectedIDs: [],
        persistedPrimarySelectionID: ""
      )
    )

    #expect(output.relativeUpdatedLabels["pr-duplicate"] != nil)
  }

  private func reviewItem(
    id: String,
    repository: String,
    number: UInt64,
    title: String = "Review",
    authorLogin: String = "renovate[bot]",
    reviewStatus: ReviewReviewStatus = .none,
    checkStatus: ReviewCheckStatus = .success,
    createdAt: String = "2026-05-01T10:00:00Z",
    updatedAt: String? = nil
  ) -> ReviewItem {
    ReviewItem(
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
