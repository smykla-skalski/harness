import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard reviews presentation worker")
struct DashboardReviewsPresentationWorkerTests {
  @Test("category=dependencies narrows results to dependency reviews")
  func categoryFilterKeepsOnlyDependencyReviews() async {
    let humanPR = reviewItem(
      id: "pr-human",
      repository: "kong/a",
      number: 1,
      title: "feat: add X",
      authorLogin: "octo-user",
      labels: []
    )
    let renovatePR = reviewItem(
      id: "pr-renovate",
      repository: "kong/a",
      number: 2,
      title: "chore(deps): bump foo",
      authorLogin: "renovate[bot]"
    )
    let dependabotPR = reviewItem(
      id: "pr-dependabot",
      repository: "kong/b",
      number: 3,
      title: "Bump bar",
      authorLogin: "dependabot[bot]"
    )
    let legacyRenovatePR = reviewItem(
      id: "pr-renovate-legacy",
      repository: "kong/c",
      number: 4,
      title: "chore(deps): bump baz",
      authorLogin: "renovate-bot"
    )
    let bareRenovatePR = reviewItem(
      id: "pr-renovate-bare",
      repository: "kong/d",
      number: 5,
      title: "chore(deps): bump qux",
      authorLogin: "renovate",
      labels: []
    )
    let labeledDependencyPR = reviewItem(
      id: "pr-labeled-dependency",
      repository: "kong/e",
      number: 6,
      title: "chore: update runtime pin",
      authorLogin: "octo-user",
      labels: ["dependencies"]
    )

    let output = await DashboardReviewsPresentationWorker().compute(
      input: DashboardReviewsPresentationInput(
        items: [
          humanPR,
          renovatePR,
          dependabotPR,
          legacyRenovatePR,
          bareRenovatePR,
          labeledDependencyPR,
        ],
        filterModeRaw: DashboardReviewsFilterMode.all.rawValue,
        sortModeRaw: DashboardReviewsSortMode.repository.rawValue,
        groupModeRaw: DashboardReviewsGroupMode.repository.rawValue,
        categoryModeRaw: DashboardReviewsCategoryMode.dependencies.rawValue,
        searchText: "",
        configuredRepositories: ["kong/a", "kong/b"],
        configuredOrganizations: [],
        configuredAuthors: [],
        selectedIDs: [],
        persistedPrimarySelectionID: ""
      )
    )

    #expect(
      Set(output.filteredItems.map(\.pullRequestID))
        == Set([
          "pr-renovate",
          "pr-dependabot",
          "pr-renovate-legacy",
          "pr-renovate-bare",
          "pr-labeled-dependency",
        ])
    )
  }

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
        groupModeRaw: DashboardReviewsGroupMode.repository.rawValue,
        categoryModeRaw: DashboardReviewsCategoryMode.all.rawValue,
        searchText: "security",
        configuredRepositories: ["kong/b", "kong/a"],
        configuredOrganizations: ["kumahq"],
        configuredAuthors: [],
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

  @Test("selection changes reuse the cached list presentation")
  func selectionChangesReuseTheCachedListPresentation() async {
    let first = reviewItem(id: "pr-1", repository: "kong/a", number: 1)
    let second = reviewItem(id: "pr-2", repository: "kong/b", number: 2)
    let worker = DashboardReviewsPresentationWorker()
    let input = DashboardReviewsPresentationInput(
      items: [first, second],
      filterModeRaw: DashboardReviewsFilterMode.all.rawValue,
      sortModeRaw: DashboardReviewsSortMode.repository.rawValue,
      groupModeRaw: DashboardReviewsGroupMode.repository.rawValue,
      categoryModeRaw: DashboardReviewsCategoryMode.all.rawValue,
      searchText: "",
      configuredRepositories: [],
      configuredOrganizations: [],
      configuredAuthors: [],
      selectedIDs: [],
      persistedPrimarySelectionID: ""
    )
    let listPresentation = await worker.computeList(
      input: DashboardReviewsListPresentationInput(input)
    )
    let emptySelection = DashboardReviewsPresentation(
      listPresentation: listPresentation,
      selectedIDs: [],
      persistedPrimarySelectionID: "",
      sortModeRaw: input.sortModeRaw
    )

    let selected = emptySelection.applyingSelection(
      selectedIDs: [second.pullRequestID],
      persistedPrimarySelectionID: "",
      sortModeRaw: input.sortModeRaw
    )

    #expect(selected.filteredItems == emptySelection.filteredItems)
    #expect(selected.groupedItems == emptySelection.groupedItems)
    #expect(selected.relativeUpdatedLabels == emptySelection.relativeUpdatedLabels)
    #expect(selected.version.listVersion == emptySelection.version.listVersion)
    #expect(selected.selectedItems.map(\.pullRequestID) == ["pr-2"])
    #expect(selected.primaryDetailItem?.pullRequestID == "pr-2")
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
        groupModeRaw: DashboardReviewsGroupMode.repository.rawValue,
        categoryModeRaw: DashboardReviewsCategoryMode.all.rawValue,
        searchText: "",
        configuredRepositories: ["kong/b", "kong/a"],
        configuredOrganizations: ["kumahq"],
        configuredAuthors: [],
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
        groupModeRaw: DashboardReviewsGroupMode.repository.rawValue,
        categoryModeRaw: DashboardReviewsCategoryMode.all.rawValue,
        searchText: "",
        configuredRepositories: [],
        configuredOrganizations: [],
        configuredAuthors: [],
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
        groupModeRaw: DashboardReviewsGroupMode.repository.rawValue,
        categoryModeRaw: DashboardReviewsCategoryMode.all.rawValue,
        searchText: "",
        configuredRepositories: [],
        configuredOrganizations: [],
        configuredAuthors: [],
        selectedIDs: [],
        persistedPrimarySelectionID: ""
      )
    )

    #expect(output.relativeUpdatedLabels["pr-duplicate"] != nil)
  }

  @Test("pinning invalidates the worker cache and reorders visible items")
  func pinningInvalidatesTheWorkerCacheAndReordersVisibleItems() async {
    let first = reviewItem(id: "pr-1", repository: "kong/a", number: 1)
    let second = reviewItem(id: "pr-2", repository: "kong/b", number: 2)
    let third = reviewItem(id: "pr-3", repository: "kong/c", number: 3)
    let worker = DashboardReviewsPresentationWorker()

    let initial = await worker.compute(
      input: DashboardReviewsPresentationInput(
        items: [first, second, third],
        filterModeRaw: DashboardReviewsFilterMode.all.rawValue,
        sortModeRaw: DashboardReviewsSortMode.repository.rawValue,
        groupModeRaw: DashboardReviewsGroupMode.flat.rawValue,
        categoryModeRaw: DashboardReviewsCategoryMode.all.rawValue,
        searchText: "",
        configuredRepositories: [],
        configuredOrganizations: [],
        configuredAuthors: [],
        selectedIDs: [],
        persistedPrimarySelectionID: "",
        pinnedPullRequestIDs: ["pr-1"]
      )
    )
    let repinned = await worker.compute(
      input: DashboardReviewsPresentationInput(
        items: [first, second, third],
        filterModeRaw: DashboardReviewsFilterMode.all.rawValue,
        sortModeRaw: DashboardReviewsSortMode.repository.rawValue,
        groupModeRaw: DashboardReviewsGroupMode.flat.rawValue,
        categoryModeRaw: DashboardReviewsCategoryMode.all.rawValue,
        searchText: "",
        configuredRepositories: [],
        configuredOrganizations: [],
        configuredAuthors: [],
        selectedIDs: [],
        persistedPrimarySelectionID: "",
        pinnedPullRequestIDs: ["pr-3"]
      )
    )

    #expect(initial.filteredItems.map(\.pullRequestID) == ["pr-1", "pr-2", "pr-3"])
    #expect(repinned.filteredItems.map(\.pullRequestID) == ["pr-3", "pr-1", "pr-2"])
    #expect(repinned.primaryDetailItem?.pullRequestID == "pr-3")
  }

  private func reviewItem(
    id: String,
    repository: String,
    number: UInt64,
    title: String = "Review",
    authorLogin: String = "renovate[bot]",
    labels: [String] = ["dependencies"],
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
      labels: labels,
      additions: 1,
      deletions: 1,
      createdAt: createdAt,
      updatedAt: updatedAt ?? createdAt
    )
  }

}
