import HarnessMonitorKit
import SwiftUI

struct DashboardReviewsPastedTextReviewSheetState: Identifiable {
  let id = UUID()
  let policyName: String
  let textPreview: String
  let references: [GitHubPullRequestReference]
  let items: [ReviewItem]
  let missingReferences: [GitHubPullRequestReference]
  let approvalPreview: ReviewsActionPreviewResponse
  let offersAutoPolicy: Bool
  let eligibleItems: [ReviewItem]
  let approvalTargetByPullRequestID: [String: ReviewActionPreviewTarget]

  init(
    policyName: String,
    textPreview: String,
    references: [GitHubPullRequestReference],
    items: [ReviewItem],
    missingReferences: [GitHubPullRequestReference],
    approvalPreview: ReviewsActionPreviewResponse,
    offersAutoPolicy: Bool
  ) {
    self.policyName = policyName
    self.textPreview = textPreview
    self.references = references
    self.items = items
    self.missingReferences = missingReferences
    self.approvalPreview = approvalPreview
    self.offersAutoPolicy = offersAutoPolicy
    self.approvalTargetByPullRequestID = Dictionary(
      uniqueKeysWithValues: approvalPreview.targets.map { ($0.pullRequestID, $0) }
    )
    let eligibleIDs = Set(
      approvalPreview.targets
        .filter(\.eligible)
        .map(\.pullRequestID)
    )
    self.eligibleItems = items.filter { eligibleIDs.contains($0.pullRequestID) }
  }

  var approveButtonTitle: String {
    eligibleItems.count == 1 ? "Approve 1 PR" : "Approve \(eligibleItems.count) PRs"
  }
}

struct DashboardReviewsPastedTextResolution {
  let items: [ReviewItem]
  let missingReferences: [GitHubPullRequestReference]
}

extension GitHubPullRequestReference {
  func matches(_ item: ReviewItem) -> Bool {
    repository.caseInsensitiveCompare(item.repository) == .orderedSame && number == item.number
  }
}

extension ReviewItem {
  var pastedReviewSubtitle: String {
    "@\(authorLogin) · \(checkStatus.title) · \(reviewStatus.title)"
  }
}

extension ReviewCheckStatus {
  fileprivate var title: String {
    switch self {
    case .none: "no checks"
    case .success: "checks passed"
    case .pending: "checks pending"
    case .failure: "checks failing"
    case .unknown(let raw): raw
    }
  }
}

extension ReviewReviewStatus {
  fileprivate var title: String {
    switch self {
    case .approved: "approved"
    case .changesRequested: "changes requested"
    case .reviewRequired: "review required"
    case .none: "no review"
    case .unknown(let raw): raw
    }
  }
}

extension ReviewPullRequestState {
  var pastedReviewTitle: String {
    switch self {
    case .open: "Open"
    case .closed: "Closed"
    case .merged: "Merged"
    case .unknown(let raw): raw
    }
  }
}
