import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard reviews filter predicates")
struct DashboardReviewsFilterPredicateTests {
  @Test("filter modes resolve to expected predicates")
  func filterModesResolveToExpectedPredicates() async {
    let fixture = makeFixture()
    let worker = DashboardReviewsPresentationWorker()

    for mode in DashboardReviewsFilterMode.pickerCases {
      let output = await worker.compute(input: input(items: fixture, filter: mode))
      switch mode {
      case .all:
        #expect(output.filteredItems.count == fixture.count)
      case .ready:
        let expected = fixture.filter(\.isAutoMergeable).map(\.pullRequestID)
        #expect(Set(output.filteredItems.map(\.pullRequestID)) == Set(expected))
      case .review:
        let expected =
          fixture
          .filter { $0.reviewStatus == .reviewRequired }
          .map(\.pullRequestID)
        #expect(Set(output.filteredItems.map(\.pullRequestID)) == Set(expected))
      case .waiting:
        let expected =
          fixture
          .filter { $0.checkStatus == .pending }
          .map(\.pullRequestID)
        #expect(Set(output.filteredItems.map(\.pullRequestID)) == Set(expected))
      }
    }
  }

  @Test("Needs Me composes ON TOP of the active filter mode")
  func needsMeComposesOnTopOfFilter() async {
    let fixture = makeFixture()
    let worker = DashboardReviewsPresentationWorker()

    let readyAndNeedsMe = await worker.compute(
      input: input(items: fixture, filter: .ready, needsMeOn: true)
    )
    let expected =
      fixture
      .filter { $0.isAutoMergeable && $0.requiresAttention }
      .map(\.pullRequestID)
    #expect(Set(readyAndNeedsMe.filteredItems.map(\.pullRequestID)) == Set(expected))

    let allAndNeedsMe = await worker.compute(
      input: input(items: fixture, filter: .all, needsMeOn: true)
    )
    let attentionOnly = fixture.filter(\.requiresAttention).map(\.pullRequestID)
    #expect(Set(allAndNeedsMe.filteredItems.map(\.pullRequestID)) == Set(attentionOnly))
  }

  @Test("Dependencies-only narrows results to dependency bots")
  func dependenciesOnlyNarrowsToDependencyBots() async {
    let fixture = makeFixture()
    let worker = DashboardReviewsPresentationWorker()

    let output = await worker.compute(
      input: input(items: fixture, filter: .all, dependenciesOnlyOn: true)
    )
    let expected =
      fixture
      .filter { ReviewBot.detect(authorLogin: $0.authorLogin) != nil }
      .map(\.pullRequestID)
    #expect(Set(output.filteredItems.map(\.pullRequestID)) == Set(expected))
    #expect(!output.filteredItems.isEmpty)
  }

  @Test("Dependencies-only and Needs Me compose")
  func dependenciesOnlyAndNeedsMeCompose() async {
    let fixture = makeFixture()
    let worker = DashboardReviewsPresentationWorker()

    let output = await worker.compute(
      input: input(items: fixture, filter: .all, needsMeOn: true, dependenciesOnlyOn: true)
    )
    let expected =
      fixture
      .filter {
        $0.requiresAttention && ReviewBot.detect(authorLogin: $0.authorLogin) != nil
      }
      .map(\.pullRequestID)
    #expect(Set(output.filteredItems.map(\.pullRequestID)) == Set(expected))
  }

  @Test("filter picker cases no longer expose .blocked")
  func filterPickerCasesDropBlocked() {
    let rawValues = DashboardReviewsFilterMode.pickerCases.map(\.rawValue)
    #expect(!rawValues.contains("blocked"))
    #expect(rawValues == ["all", "ready", "review", "waiting"])
  }

  private func input(
    items: [ReviewItem],
    filter: DashboardReviewsFilterMode,
    needsMeOn: Bool = false,
    dependenciesOnlyOn: Bool = false
  ) -> DashboardReviewsPresentationInput {
    DashboardReviewsPresentationInput(
      items: items,
      filterModeRaw: filter.rawValue,
      sortModeRaw: DashboardReviewsSortMode.repository.rawValue,
      categoryModeRaw: DashboardReviewsCategoryMode.defaultMode.rawValue,
      searchText: "",
      configuredRepositories: [],
      configuredOrganizations: [],
      selectedIDs: [],
      persistedPrimarySelectionID: "",
      needsMeOn: needsMeOn,
      dependenciesOnlyOn: dependenciesOnlyOn
    )
  }

  private func makeFixture() -> [ReviewItem] {
    [
      // ready + auto-mergeable, no attention required.
      reviewItem(
        id: "pr-ready-clean",
        authorLogin: "octo-user",
        reviewStatus: .approved,
        checkStatus: .success
      ),
      // ready + auto-mergeable, requires attention (changes requested).
      reviewItem(
        id: "pr-ready-attention",
        authorLogin: "renovate[bot]",
        reviewStatus: .changesRequested,
        checkStatus: .success
      ),
      // needs review.
      reviewItem(
        id: "pr-review",
        authorLogin: "octo-user",
        reviewStatus: .reviewRequired,
        checkStatus: .success
      ),
      // waiting on checks.
      reviewItem(
        id: "pr-waiting",
        authorLogin: "dependabot[bot]",
        reviewStatus: .approved,
        checkStatus: .pending
      ),
      // attention required (failing checks).
      reviewItem(
        id: "pr-attention",
        authorLogin: "octo-user",
        reviewStatus: .approved,
        checkStatus: .failure
      ),
      // dependency bot, needs review.
      reviewItem(
        id: "pr-dep-review",
        authorLogin: "renovate[bot]",
        reviewStatus: .reviewRequired,
        checkStatus: .success
      ),
      // dependency bot using the legacy Renovate login variant.
      reviewItem(
        id: "pr-dep-legacy-attention",
        authorLogin: "renovate-bot",
        reviewStatus: .changesRequested,
        checkStatus: .success
      ),
    ]
  }

  private func reviewItem(
    id: String,
    authorLogin: String,
    reviewStatus: ReviewReviewStatus,
    checkStatus: ReviewCheckStatus
  ) -> ReviewItem {
    ReviewItem(
      pullRequestID: id,
      repositoryID: "repo-kong/a",
      repository: "kong/a",
      number: 1,
      title: "Title \(id)",
      url: "https://github.com/kong/a/pull/1",
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
