import HarnessMonitorKit
import SwiftUI

struct DashboardReviewsPastedTextReviewSheetState: Identifiable {
  let id = UUID()
  let policyName: String
  let textPreview: String
  let references: [GitHubPullRequestReference]
  let items: [ReviewItem]
  let missingReferences: [GitHubPullRequestReference]
  let extractionRows: [ReviewPullRequestExtractionResolvedRow]
  let outputText: String
  let approvalPreview: ReviewsActionPreviewResponse
  let offersAutoPolicy: Bool
  let dryRun: Bool
  let allowsApprovalActions: Bool
  let eligibleItems: [ReviewItem]
  let approvalTargetByPullRequestID: [String: ReviewActionPreviewTarget]

  init(
    policyName: String,
    textPreview: String,
    references: [GitHubPullRequestReference],
    items: [ReviewItem],
    missingReferences: [GitHubPullRequestReference],
    extractionRows: [ReviewPullRequestExtractionResolvedRow] = [],
    outputText: String = "",
    approvalPreview: ReviewsActionPreviewResponse,
    offersAutoPolicy: Bool,
    dryRun: Bool,
    allowsApprovalActions: Bool = true
  ) {
    self.policyName = policyName
    self.textPreview = textPreview
    self.references = references
    self.items = items
    self.missingReferences = missingReferences
    self.extractionRows = extractionRows
    self.outputText = outputText
    self.approvalPreview = approvalPreview
    self.offersAutoPolicy = offersAutoPolicy
    self.dryRun = dryRun
    self.allowsApprovalActions = allowsApprovalActions
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
    let countText = eligibleItems.count == 1 ? "1 PR" : "\(eligibleItems.count) PRs"
    return dryRun ? "Dry Run \(countText)" : "Approve \(countText)"
  }

  var copiedCount: Int {
    extractionRows.isEmpty
      ? items.count
      : extractionRows.count(where: \.isSelectedForOutput)
  }

  var foundCount: Int {
    extractionRows.isEmpty ? references.count : extractionRows.count
  }

  var ambiguousRows: [ReviewPullRequestExtractionResolvedRow] {
    extractionRows.filter { $0.status == .ambiguous }
  }

  var missingRows: [ReviewPullRequestExtractionResolvedRow] {
    extractionRows.filter { $0.status == .missing }
  }
}

struct DashboardReviewsPastedTextResolution {
  let items: [ReviewItem]
  let missingReferences: [GitHubPullRequestReference]
  let extractionRows: [ReviewPullRequestExtractionResolvedRow]
  let outputText: String

  init(
    items: [ReviewItem],
    missingReferences: [GitHubPullRequestReference],
    extractionRows: [ReviewPullRequestExtractionResolvedRow] = [],
    outputText: String = ""
  ) {
    self.items = items
    self.missingReferences = missingReferences
    self.extractionRows = extractionRows
    self.outputText = outputText
  }
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
