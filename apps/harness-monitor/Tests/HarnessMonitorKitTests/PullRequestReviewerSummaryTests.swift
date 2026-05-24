import XCTest

@testable import HarnessMonitorKit

final class PullRequestReviewerSummaryTests: XCTestCase {
  func testEmptyReviewsZeroBothCounts() {
    let summary = PullRequestReviewerSummary(reviews: [])

    XCTAssertEqual(summary.approvedCount, 0)
    XCTAssertEqual(summary.reviewerCount, 0)
    XCTAssertEqual(summary.label, "0/0 approvals")
  }

  func testCountsUniqueAuthorsAndApprovals() {
    let summary = PullRequestReviewerSummary(reviews: [
      PullRequestReview(author: "alice", state: .approved),
      PullRequestReview(author: "bob", state: .changesRequested),
      PullRequestReview(author: "carol", state: .commented),
      PullRequestReview(author: "alice", state: .approved)
    ])

    XCTAssertEqual(summary.approvedCount, 1)
    XCTAssertEqual(summary.reviewerCount, 3)
    XCTAssertEqual(summary.label, "1/3 approvals")
  }

  func testLastStatePerAuthorWins() {
    let summary = PullRequestReviewerSummary(reviews: [
      PullRequestReview(author: "alice", state: .changesRequested),
      PullRequestReview(author: "alice", state: .approved)
    ])

    XCTAssertEqual(summary.label, "1/1 approvals")
  }

  func testBlankAuthorsIgnored() {
    let summary = PullRequestReviewerSummary(reviews: [
      PullRequestReview(author: "", state: .approved),
      PullRequestReview(author: "", state: .approved),
      PullRequestReview(author: "alice", state: .commented)
    ])

    XCTAssertEqual(summary.label, "0/1 approvals")
  }

  func testDirectInitClampsImpossibleApprovedCount() {
    let summary = PullRequestReviewerSummary(approvedCount: 99, reviewerCount: 2)

    XCTAssertEqual(summary.approvedCount, 2)
    XCTAssertEqual(summary.reviewerCount, 2)
  }

  func testDirectInitClampsNegatives() {
    let summary = PullRequestReviewerSummary(approvedCount: -5, reviewerCount: -3)

    XCTAssertEqual(summary.approvedCount, 0)
    XCTAssertEqual(summary.reviewerCount, 0)
  }
}
