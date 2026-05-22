import Testing

@testable import HarnessMonitorKit

@Suite("applyDependencyRefresh merges targeted refresh results")
struct DependencyUpdatesRefreshMergeTests {
  @Test("replaces matching open item in place and leaves others untouched")
  func replacesMatchingOpenItem() {
    let original = item(id: "pr-1", reviewStatus: .reviewRequired)
    let other = item(id: "pr-2", reviewStatus: .reviewRequired)
    let refreshedOne = item(id: "pr-1", reviewStatus: .approved)

    let next = applyDependencyRefresh(
      to: [original, other],
      refresh: DependencyUpdatesRefreshResponse(
        fetchedAt: "2026-05-21T12:00:00Z",
        items: [refreshedOne]
      )
    )

    #expect(next.count == 2)
    #expect(next[0].pullRequestID == "pr-1")
    #expect(next[0].reviewStatus == .approved)
    #expect(next[1].pullRequestID == "pr-2")
    #expect(next[1].reviewStatus == .reviewRequired)
  }

  @Test("drops items whose refreshed state is no longer open")
  func dropsClosedOrMergedItems() {
    let original = item(id: "pr-1", state: .open)
    let other = item(id: "pr-2", state: .open)
    let mergedRefresh = item(id: "pr-1", state: .merged)

    let next = applyDependencyRefresh(
      to: [original, other],
      refresh: DependencyUpdatesRefreshResponse(
        fetchedAt: "2026-05-21T12:00:00Z",
        items: [mergedRefresh]
      )
    )

    #expect(next.map(\.pullRequestID) == ["pr-2"])
  }

  @Test("drops items reported as missing")
  func dropsMissingIDs() {
    let first = item(id: "pr-1")
    let second = item(id: "pr-2")

    let next = applyDependencyRefresh(
      to: [first, second],
      refresh: DependencyUpdatesRefreshResponse(
        fetchedAt: "2026-05-21T12:00:00Z",
        missingPullRequestIDs: ["pr-1"]
      )
    )

    #expect(next.map(\.pullRequestID) == ["pr-2"])
  }

  @Test("ignores refreshed items that do not match any cached entry")
  func ignoresUnknownRefreshedItems() {
    let only = item(id: "pr-1", reviewStatus: .reviewRequired)
    let unknown = item(id: "pr-other", reviewStatus: .approved)

    let next = applyDependencyRefresh(
      to: [only],
      refresh: DependencyUpdatesRefreshResponse(
        fetchedAt: "2026-05-21T12:00:00Z",
        items: [unknown]
      )
    )

    #expect(next.count == 1)
    #expect(next[0].pullRequestID == "pr-1")
    #expect(next[0].reviewStatus == .reviewRequired)
  }

  @Test("collapses duplicate cached ids before applying refreshed replacements")
  func collapsesDuplicateCachedIDsBeforeReplacing() {
    let older = item(
      id: "pr-1",
      reviewStatus: .reviewRequired,
      updatedAt: "2026-05-20T12:00:00Z"
    )
    let duplicate = item(
      id: "pr-1",
      reviewStatus: .reviewRequired,
      updatedAt: "2026-05-20T12:30:00Z"
    )
    let other = item(id: "pr-2", reviewStatus: .reviewRequired)
    let refreshed = item(
      id: "pr-1",
      reviewStatus: .approved,
      updatedAt: "2026-05-21T12:00:00Z"
    )

    let next = applyDependencyRefresh(
      to: [older, duplicate, other],
      refresh: DependencyUpdatesRefreshResponse(
        fetchedAt: "2026-05-21T12:00:00Z",
        items: [refreshed]
      )
    )

    #expect(next.map(\.pullRequestID) == ["pr-1", "pr-2"])
    #expect(next[0].reviewStatus == .approved)
  }

  @Test("returns empty result when the refresh wipes the entire list")
  func clearsListWhenAllDropped() {
    let one = item(id: "pr-1", state: .open)
    let two = item(id: "pr-2", state: .open)

    let next = applyDependencyRefresh(
      to: [one, two],
      refresh: DependencyUpdatesRefreshResponse(
        fetchedAt: "2026-05-21T12:00:00Z",
        items: [item(id: "pr-1", state: .merged)],
        missingPullRequestIDs: ["pr-2"]
      )
    )

    #expect(next.isEmpty)
  }

  private func item(
    id: String,
    state: DependencyUpdatePullRequestState = .open,
    reviewStatus: DependencyUpdateReviewStatus = .reviewRequired,
    updatedAt: String = "2026-05-20T12:00:00Z"
  ) -> DependencyUpdateItem {
    DependencyUpdateItem(
      pullRequestID: id,
      repositoryID: "repo-1",
      repository: "acme/api",
      number: 1,
      title: "Dependency update",
      url: "https://github.com/acme/api/pull/1",
      authorLogin: "renovate[bot]",
      state: state,
      mergeable: .mergeable,
      reviewStatus: reviewStatus,
      checkStatus: .success,
      policyBlocked: false,
      isDraft: false,
      headSha: "sha-\(id)",
      labels: [],
      additions: 1,
      deletions: 1,
      createdAt: "2026-05-20T12:00:00Z",
      updatedAt: updatedAt
    )
  }
}
