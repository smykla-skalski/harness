import Foundation
import HarnessMonitorCore
import XCTest

final class MobileAttentionReviewLinkTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_000_000)

  private func pullRequestAttention(reviewID: String?) -> MobileAttentionItem {
    MobileAttentionItem(
      id: "derived-review-\(reviewID ?? "none")",
      stationID: "station-a",
      kind: .pullRequest,
      severity: .warning,
      title: "Review",
      subtitle: "PR",
      updatedAt: now,
      target: reviewID.map {
        MobileCommandTarget(stationID: "station-a", reviewID: $0, targetRevision: 1)
      }
    )
  }

  func testPullRequestAttentionResolvesMatchingReviewID() {
    let review = mobileReview("r1", stationID: "station-a", now: now)
    let item = pullRequestAttention(reviewID: "r1")
    XCTAssertEqual(item.navigableReviewID(in: [review]), "r1")
  }

  func testPullRequestAttentionWithoutMatchingReviewReturnsNil() {
    let review = mobileReview("r1", stationID: "station-a", now: now)
    let item = pullRequestAttention(reviewID: "missing")
    XCTAssertNil(item.navigableReviewID(in: [review]))
  }

  func testNonPullRequestAttentionReturnsNil() {
    let review = mobileReview("r1", stationID: "station-a", now: now)
    let item = MobileAttentionItem(
      id: "derived-task-r1",
      stationID: "station-a",
      kind: .taskBoard,
      severity: .warning,
      title: "Task",
      subtitle: "x",
      updatedAt: now,
      target: MobileCommandTarget(stationID: "station-a", reviewID: "r1", targetRevision: 1)
    )
    XCTAssertNil(item.navigableReviewID(in: [review]))
  }
}
