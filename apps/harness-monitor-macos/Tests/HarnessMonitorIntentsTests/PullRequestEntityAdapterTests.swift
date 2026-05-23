import Foundation
import HarnessMonitorKit
import XCTest

@testable import HarnessMonitorIntents

final class PullRequestEntityAdapterTests: XCTestCase {
  func testOpenPullRequestMapsCleanly() {
    let item = Self.makeItem(
      pullRequestID: "owner/repo#42",
      title: "Update README",
      state: .open,
      isDraft: false,
      reviews: []
    )

    let entity = PullRequestEntity(from: item)

    XCTAssertEqual(entity.id, "owner/repo#42")
    XCTAssertEqual(entity.repository, "owner/repo")
    XCTAssertEqual(entity.number, 42)
    XCTAssertEqual(entity.title, "Update README")
    XCTAssertEqual(entity.authorLogin, "alice")
    XCTAssertEqual(entity.state, .open)
    XCTAssertEqual(entity.reviewerSummary, "0/0 approvals")
    XCTAssertEqual(entity.url, URL(string: "https://github.com/owner/repo/pull/42"))
  }

  func testDraftPullRequestStateMapsToDraftEvenWhenStateOpen() {
    let item = Self.makeItem(
      pullRequestID: "owner/repo#43",
      title: "WIP",
      state: .open,
      isDraft: true,
      reviews: []
    )

    let entity = PullRequestEntity(from: item)

    XCTAssertEqual(entity.state, .draft)
  }

  func testMergedAndClosedStatesMap() {
    let merged = PullRequestEntity(
      from: Self.makeItem(
        pullRequestID: "owner/repo#44",
        title: "Done",
        state: .merged,
        isDraft: false,
        reviews: []
      )
    )
    let closed = PullRequestEntity(
      from: Self.makeItem(
        pullRequestID: "owner/repo#45",
        title: "Abandoned",
        state: .closed,
        isDraft: false,
        reviews: []
      )
    )
    let unknown = PullRequestEntity(
      from: Self.makeItem(
        pullRequestID: "owner/repo#46",
        title: "Mystery",
        state: .unknown("weird"),
        isDraft: false,
        reviews: []
      )
    )

    XCTAssertEqual(merged.state, .merged)
    XCTAssertEqual(closed.state, .closed)
    XCTAssertEqual(unknown.state, .closed)
  }

  func testReviewerSummaryCountsUniqueAuthorsAndApprovals() {
    let item = Self.makeItem(
      pullRequestID: "owner/repo#47",
      title: "Review summary",
      state: .open,
      isDraft: false,
      reviews: [
        PullRequestReview(author: "alice", state: .approved),
        PullRequestReview(author: "bob", state: .changesRequested),
        PullRequestReview(author: "carol", state: .commented),
        PullRequestReview(author: "alice", state: .approved)
      ]
    )

    let entity = PullRequestEntity(from: item)

    XCTAssertEqual(entity.reviewerSummary, "1/3 approvals")
  }

  func testReviewerSummaryReflectsLastStateWhenAuthorRereviews() {
    let item = Self.makeItem(
      pullRequestID: "owner/repo#48",
      title: "Re-review",
      state: .open,
      isDraft: false,
      reviews: [
        PullRequestReview(author: "alice", state: .changesRequested),
        PullRequestReview(author: "alice", state: .approved)
      ]
    )

    let entity = PullRequestEntity(from: item)

    XCTAssertEqual(entity.reviewerSummary, "1/1 approvals")
  }

  func testReviewerSummaryIgnoresEmptyAuthors() {
    let item = Self.makeItem(
      pullRequestID: "owner/repo#49",
      title: "Blank authors",
      state: .open,
      isDraft: false,
      reviews: [
        PullRequestReview(author: "", state: .approved),
        PullRequestReview(author: "", state: .approved),
        PullRequestReview(author: "alice", state: .commented)
      ]
    )

    let entity = PullRequestEntity(from: item)

    XCTAssertEqual(entity.reviewerSummary, "0/1 approvals")
  }

  func testBlankAuthorLoginCollapsesToNil() {
    let item = Self.makeItem(
      pullRequestID: "owner/repo#50",
      title: "No author",
      state: .open,
      isDraft: false,
      reviews: [],
      overrideAuthorLogin: "   "
    )

    let entity = PullRequestEntity(from: item)

    XCTAssertNil(entity.authorLogin)
  }

  func testLastUpdatedParsesISO8601Timestamps() {
    let item = Self.makeItem(
      pullRequestID: "owner/repo#51",
      title: "Timestamps",
      state: .open,
      isDraft: false,
      reviews: [],
      overrideUpdatedAt: "2026-05-23T15:30:00Z"
    )

    let entity = PullRequestEntity(from: item)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]

    XCTAssertEqual(entity.lastUpdated, formatter.date(from: "2026-05-23T15:30:00Z"))
  }

  func testLastUpdatedIsNilForUnparseableTimestamps() {
    let item = Self.makeItem(
      pullRequestID: "owner/repo#52",
      title: "Bad date",
      state: .open,
      isDraft: false,
      reviews: [],
      overrideUpdatedAt: "not a date"
    )

    let entity = PullRequestEntity(from: item)

    XCTAssertNil(entity.lastUpdated)
  }

  func testUrlIsNilForMalformedString() {
    let item = Self.makeItem(
      pullRequestID: "owner/repo#53",
      title: "Bad URL",
      state: .open,
      isDraft: false,
      reviews: [],
      overrideURL: ""
    )

    let entity = PullRequestEntity(from: item)

    XCTAssertNil(entity.url)
  }

  // MARK: - helpers

  private static func makeItem(
    pullRequestID: String,
    title: String,
    state: ReviewPullRequestState,
    isDraft: Bool,
    reviews: [PullRequestReview],
    overrideAuthorLogin: String = "alice",
    overrideUpdatedAt: String = "2026-05-23T12:00:00Z",
    overrideURL: String? = nil
  ) -> ReviewItem {
    let parts = pullRequestID.components(separatedBy: "#")
    let repo = parts.first ?? "owner/repo"
    let numberString = parts.count > 1 ? parts[1] : "0"
    let number = UInt64(numberString) ?? 0
    let url = overrideURL ?? "https://github.com/\(repo)/pull/\(number)"
    return ReviewItem(
      pullRequestID: pullRequestID,
      repositoryID: repo,
      repository: repo,
      number: number,
      title: title,
      url: url,
      authorLogin: overrideAuthorLogin,
      state: state,
      mergeable: .mergeable,
      reviewStatus: .none,
      checkStatus: .success,
      policyBlocked: false,
      isDraft: isDraft,
      headSha: "abc123",
      labels: [],
      checks: [],
      reviews: reviews,
      additions: 1,
      deletions: 1,
      createdAt: "2026-05-22T10:00:00Z",
      updatedAt: overrideUpdatedAt,
      requiredFailedCheckNames: [],
      viewerCanUpdate: true,
      viewerCanMergeAsAdmin: false
    )
  }
}
