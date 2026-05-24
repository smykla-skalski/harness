import Foundation

/// Canonical reviewer-summary aggregation for a pull request, shared by
/// the Dashboard reviewer pill and the App Intent `PullRequestEntity`
/// surface so the two cannot drift. Algorithm: collapse reviews by
/// author (keeping each author's most-recent state), then count unique
/// authors and how many of them last left an approval. Blank authors
/// are ignored
public struct PullRequestReviewerSummary: Equatable, Sendable {
  public let approvedCount: Int
  public let reviewerCount: Int

  public init(approvedCount: Int, reviewerCount: Int) {
    let clampedReviewers = max(0, reviewerCount)
    self.reviewerCount = clampedReviewers
    self.approvedCount = max(0, min(approvedCount, clampedReviewers))
  }

  public init(reviews: [PullRequestReview]) {
    var lastStateByAuthor: [String: ReviewReviewEventState] = [:]
    for review in reviews where !review.author.isEmpty {
      lastStateByAuthor[review.author] = review.state
    }
    let approved = lastStateByAuthor.values.count { $0 == .approved }
    self.init(approvedCount: approved, reviewerCount: lastStateByAuthor.count)
  }

  /// Short label rendered in the dashboard pill and in the App Intent
  /// entity. Stable wording; tests pin the exact string
  public var label: String {
    "\(approvedCount)/\(reviewerCount) approvals"
  }
}
