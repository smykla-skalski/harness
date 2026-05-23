import Foundation
import HarnessMonitorKit
import XCTest

@testable import HarnessMonitorIntents

final class ReviewsIntentTests: XCTestCase {
  func testGetNeedsMeCountReturnsZeroWhenSourceEmpty() async throws {
    let stub = StubPullRequestSource()
    let intent = GetNeedsMeCountIntent(source: stub)

    let count = try await intent.resolveCount()

    XCTAssertEqual(count, 0)
  }

  func testGetNeedsMeCountFiltersToRequiresAttention() async throws {
    let stub = StubPullRequestSource(
      suggestedResult: [
        Self.makeItem(pullRequestID: "owner/repo#1", title: "Clean"),
        Self.makeItem(
          pullRequestID: "owner/repo#2",
          title: "Conflicting",
          mergeable: .conflicting
        ),
        Self.makeItem(
          pullRequestID: "owner/repo#3",
          title: "Policy blocked",
          policyBlocked: true
        ),
        Self.makeItem(
          pullRequestID: "owner/repo#4",
          title: "Changes requested",
          reviewStatus: .changesRequested
        )
      ]
    )
    let intent = GetNeedsMeCountIntent(source: stub)

    let count = try await intent.resolveCount()

    XCTAssertEqual(count, 3)
  }

  func testSearchPullRequestsReturnsEmptyForBlankQuery() async throws {
    let stub = StubPullRequestSource(
      searchResult: [
        Self.makeItem(pullRequestID: "owner/repo#1", title: "Renovate")
      ]
    )
    let intent = SearchPullRequestsIntent(query: "   \t", source: stub)

    let entities = try await intent.resolveEntities()

    XCTAssertTrue(entities.isEmpty)
    let recorded = await stub.recordedSearches
    XCTAssertTrue(recorded.isEmpty, "blank query must skip the source call")
  }

  func testSearchPullRequestsForwardsTrimmedQueryToSource() async throws {
    let stub = StubPullRequestSource(
      searchResult: [
        Self.makeItem(pullRequestID: "owner/repo#1", title: "Renovate"),
        Self.makeItem(pullRequestID: "owner/repo#2", title: "Renovate again")
      ]
    )
    let intent = SearchPullRequestsIntent(query: "  Renovate  ", source: stub)

    let entities = try await intent.resolveEntities()

    XCTAssertEqual(entities.map(\.id), ["owner/repo#1", "owner/repo#2"])
    let recorded = await stub.recordedSearches
    XCTAssertEqual(recorded.count, 1)
    XCTAssertEqual(recorded.first?.query, "Renovate")
    XCTAssertEqual(recorded.first?.limit, 50)
  }

  // MARK: - helpers

  private static func makeItem(
    pullRequestID: String,
    title: String,
    mergeable: ReviewMergeableState = .mergeable,
    reviewStatus: ReviewReviewStatus = .none,
    checkStatus: ReviewCheckStatus = .success,
    policyBlocked: Bool = false
  ) -> ReviewItem {
    let parts = pullRequestID.components(separatedBy: "#")
    let repo = parts.first ?? "owner/repo"
    let number = UInt64(parts.count > 1 ? parts[1] : "0") ?? 0
    return ReviewItem(
      pullRequestID: pullRequestID,
      repositoryID: repo,
      repository: repo,
      number: number,
      title: title,
      url: "https://github.com/\(repo)/pull/\(number)",
      authorLogin: "alice",
      state: .open,
      mergeable: mergeable,
      reviewStatus: reviewStatus,
      checkStatus: checkStatus,
      policyBlocked: policyBlocked,
      isDraft: false,
      headSha: "abc123",
      labels: [],
      checks: [],
      reviews: [],
      additions: 0,
      deletions: 0,
      createdAt: "2026-05-22T10:00:00Z",
      updatedAt: "2026-05-23T12:00:00Z"
    )
  }
}
