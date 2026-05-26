import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard reviews grouping")
struct DashboardReviewsGroupingTests {
  @Test("status grouping yields sections ordered by status bucket")
  func statusGroupingProducesBucketOrderedSections() async {
    let ready = item(
      id: "ready",
      repository: "kong/a",
      number: 1,
      reviewStatus: .approved,
      checkStatus: .success
    )
    let waiting = item(
      id: "waiting",
      repository: "kong/b",
      number: 2,
      reviewStatus: .none,
      checkStatus: .pending
    )
    let attention = item(
      id: "attention",
      repository: "kong/c",
      number: 3,
      reviewStatus: .changesRequested,
      checkStatus: .success
    )

    let output = await DashboardReviewsPresentationWorker().compute(
      input: DashboardReviewsPresentationInput(
        items: [attention, waiting, ready],
        filterModeRaw: DashboardReviewsFilterMode.all.rawValue,
        sortModeRaw: DashboardReviewsSortMode.status.rawValue,
        groupModeRaw: DashboardReviewsGroupMode.status.rawValue,
        categoryModeRaw: DashboardReviewsCategoryMode.all.rawValue,
        searchText: "",
        configuredRepositories: [],
        configuredOrganizations: [],
        configuredAuthors: [],
        selectedIDs: [],
        persistedPrimarySelectionID: ""
      )
    )

    #expect(output.groupedItems.count == 3)
    let kinds = output.groupedItems.map(\.kind.title)
    let firstIDs = output.groupedItems.compactMap(\.items.first?.pullRequestID)
    #expect(firstIDs == ["ready", "waiting", "attention"])
    #expect(kinds == ["Ready to merge", "Checks running", "Needs attention"])
  }

  @Test("author grouping puts configured authors first and falls back to alphabetic")
  func authorGroupingHonorsConfiguredAuthorOrder() async {
    let renovate = item(
      id: "renovate",
      repository: "kong/a",
      number: 1,
      authorLogin: "renovate[bot]"
    )
    let alice = item(
      id: "alice",
      repository: "kong/a",
      number: 2,
      authorLogin: "alice"
    )
    let bob = item(
      id: "bob",
      repository: "kong/b",
      number: 3,
      authorLogin: "bob"
    )

    let output = await DashboardReviewsPresentationWorker().compute(
      input: DashboardReviewsPresentationInput(
        items: [bob, alice, renovate],
        filterModeRaw: DashboardReviewsFilterMode.all.rawValue,
        sortModeRaw: DashboardReviewsSortMode.repository.rawValue,
        groupModeRaw: DashboardReviewsGroupMode.author.rawValue,
        categoryModeRaw: DashboardReviewsCategoryMode.all.rawValue,
        searchText: "",
        configuredRepositories: [],
        configuredOrganizations: [],
        configuredAuthors: ["renovate[bot]"],
        selectedIDs: [],
        persistedPrimarySelectionID: ""
      )
    )

    let titles = output.groupedItems.map(\.kind.title)
    #expect(titles == ["renovate[bot]", "alice", "bob"])
    for group in output.groupedItems {
      if case .author = group.kind { continue }
      Issue.record("Expected author kind, got \(group.kind)")
    }
  }

  @Test("author grouping returns alphabetic order when no configured authors match")
  func authorGroupingFallsBackToAlphabetic() async {
    let renovate = item(
      id: "renovate",
      repository: "kong/a",
      number: 1,
      authorLogin: "renovate[bot]"
    )
    let alice = item(
      id: "alice",
      repository: "kong/a",
      number: 2,
      authorLogin: "alice"
    )

    let output = await DashboardReviewsPresentationWorker().compute(
      input: DashboardReviewsPresentationInput(
        items: [renovate, alice],
        filterModeRaw: DashboardReviewsFilterMode.all.rawValue,
        sortModeRaw: DashboardReviewsSortMode.repository.rawValue,
        groupModeRaw: DashboardReviewsGroupMode.author.rawValue,
        categoryModeRaw: DashboardReviewsCategoryMode.all.rawValue,
        searchText: "",
        configuredRepositories: [],
        configuredOrganizations: [],
        configuredAuthors: [],
        selectedIDs: [],
        persistedPrimarySelectionID: ""
      )
    )

    #expect(output.groupedItems.map(\.kind.title) == ["alice", "renovate[bot]"])
  }

  @Test("repository grouping (default) still yields configured-repository order")
  func repositoryGroupingHonorsConfiguredOrder() async {
    let aPR = item(id: "a", repository: "kong/a", number: 1)
    let bPR = item(id: "b", repository: "kong/b", number: 2)

    let output = await DashboardReviewsPresentationWorker().compute(
      input: DashboardReviewsPresentationInput(
        items: [aPR, bPR],
        filterModeRaw: DashboardReviewsFilterMode.all.rawValue,
        sortModeRaw: DashboardReviewsSortMode.repository.rawValue,
        groupModeRaw: DashboardReviewsGroupMode.repository.rawValue,
        categoryModeRaw: DashboardReviewsCategoryMode.all.rawValue,
        searchText: "",
        configuredRepositories: ["kong/b", "kong/a"],
        configuredOrganizations: [],
        configuredAuthors: [],
        selectedIDs: [],
        persistedPrimarySelectionID: ""
      )
    )

    let kinds = output.groupedItems.map(\.kind)
    #expect(kinds == [.repository("kong/b"), .repository("kong/a")])
  }

  @Test("repository grouping lifts pinned PRs into a top-level pinned section")
  func repositoryGroupingLiftsPinnedPRsIntoATopLevelSection() async {
    let pinned = item(id: "pinned", repository: "kong/b", number: 2)
    let remaining = item(id: "remaining", repository: "kong/a", number: 1)

    let output = await DashboardReviewsPresentationWorker().compute(
      input: DashboardReviewsPresentationInput(
        items: [remaining, pinned],
        filterModeRaw: DashboardReviewsFilterMode.all.rawValue,
        sortModeRaw: DashboardReviewsSortMode.repository.rawValue,
        groupModeRaw: DashboardReviewsGroupMode.repository.rawValue,
        categoryModeRaw: DashboardReviewsCategoryMode.all.rawValue,
        searchText: "",
        configuredRepositories: ["kong/a", "kong/b"],
        configuredOrganizations: [],
        configuredAuthors: [],
        selectedIDs: [],
        persistedPrimarySelectionID: "",
        pinnedPullRequestIDs: ["pinned"]
      )
    )

    #expect(output.groupedItems.first?.kind == .pinned)
    #expect(output.groupedItems.first?.items.map(\.pullRequestID) == ["pinned"])
    #expect(output.groupedItems.dropFirst().map(\.kind) == [.repository("kong/a")])
  }

  @Test("repository grouping floats pinned repositories above the configured order")
  func repositoryGroupingFloatsPinnedRepositoriesFirst() async {
    let aPR = item(id: "a", repository: "kong/a", number: 1)
    let bPR = item(id: "b", repository: "kong/b", number: 2)
    let cPR = item(id: "c", repository: "kong/c", number: 3)

    let output = await DashboardReviewsPresentationWorker().compute(
      input: DashboardReviewsPresentationInput(
        items: [aPR, bPR, cPR],
        filterModeRaw: DashboardReviewsFilterMode.all.rawValue,
        sortModeRaw: DashboardReviewsSortMode.repository.rawValue,
        groupModeRaw: DashboardReviewsGroupMode.repository.rawValue,
        categoryModeRaw: DashboardReviewsCategoryMode.all.rawValue,
        searchText: "",
        configuredRepositories: ["kong/a", "kong/b", "kong/c"],
        configuredOrganizations: [],
        configuredAuthors: [],
        selectedIDs: [],
        persistedPrimarySelectionID: "",
        pinnedRepositoryIDs: ["kong/c"]
      )
    )

    let kinds = output.groupedItems.map(\.kind)
    #expect(kinds == [.repository("kong/c"), .repository("kong/a"), .repository("kong/b")])
  }

  @Test("repository grouping keeps the pinned-PR section above pinned repositories")
  func repositoryGroupingKeepsPinnedPRSectionAbovePinnedRepositories() async {
    let pinnedPR = item(id: "pinned", repository: "kong/a", number: 1)
    let bPR = item(id: "b", repository: "kong/b", number: 2)
    let cPR = item(id: "c", repository: "kong/c", number: 3)

    let output = await DashboardReviewsPresentationWorker().compute(
      input: DashboardReviewsPresentationInput(
        items: [pinnedPR, bPR, cPR],
        filterModeRaw: DashboardReviewsFilterMode.all.rawValue,
        sortModeRaw: DashboardReviewsSortMode.repository.rawValue,
        groupModeRaw: DashboardReviewsGroupMode.repository.rawValue,
        categoryModeRaw: DashboardReviewsCategoryMode.all.rawValue,
        searchText: "",
        configuredRepositories: ["kong/a", "kong/b", "kong/c"],
        configuredOrganizations: [],
        configuredAuthors: [],
        selectedIDs: [],
        persistedPrimarySelectionID: "",
        pinnedPullRequestIDs: ["pinned"],
        pinnedRepositoryIDs: ["kong/c"]
      )
    )

    let kinds = output.groupedItems.map(\.kind)
    #expect(kinds == [.pinned, .repository("kong/c"), .repository("kong/b")])
  }

  @Test("flat grouping returns no groups; consumers fall back to filtered items")
  func flatGroupingReturnsEmptySections() async {
    let pr = item(id: "pr", repository: "kong/a", number: 1)

    let output = await DashboardReviewsPresentationWorker().compute(
      input: DashboardReviewsPresentationInput(
        items: [pr],
        filterModeRaw: DashboardReviewsFilterMode.all.rawValue,
        sortModeRaw: DashboardReviewsSortMode.repository.rawValue,
        groupModeRaw: DashboardReviewsGroupMode.flat.rawValue,
        categoryModeRaw: DashboardReviewsCategoryMode.all.rawValue,
        searchText: "",
        configuredRepositories: [],
        configuredOrganizations: [],
        configuredAuthors: [],
        selectedIDs: [],
        persistedPrimarySelectionID: ""
      )
    )

    #expect(output.groupedItems.isEmpty)
    #expect(output.filteredItems.map(\.pullRequestID) == ["pr"])
  }

  // MARK: helpers

  private func item(
    id: String,
    repository: String,
    number: UInt64,
    title: String = "Review",
    authorLogin: String = "user",
    reviewStatus: ReviewReviewStatus = .none,
    checkStatus: ReviewCheckStatus = .success
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
      labels: [],
      additions: 1,
      deletions: 1,
      createdAt: "2026-05-01T10:00:00Z",
      updatedAt: "2026-05-01T10:00:00Z"
    )
  }
}
