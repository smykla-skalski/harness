import HarnessMonitorKit

enum DashboardReviewsDisabledReason {
  static func approveReason(for items: [ReviewItem]) -> String? {
    if items.isEmpty { return "No pull requests selected" }
    if items.contains(where: { $0.canAttemptManualApproval }) { return nil }
    if items.allSatisfy({ !$0.viewerCanUpdate }) { return updatePermissionReason }
    if items.allSatisfy({ $0.state != .open }) { return "Pull request is not open" }
    if items.allSatisfy({ $0.reviewStatus == .approved }) { return "Already approved" }
    if items.allSatisfy({ $0.reviewStatus == .changesRequested }) {
      return "Changes requested - resolve review before approving"
    }
    return "Nothing in this selection needs approval"
  }

  static func mergeReason(for items: [ReviewItem]) -> String? {
    if items.isEmpty { return "No pull requests selected" }
    if items.contains(where: { $0.canAttemptManualMerge }) { return nil }
    if items.allSatisfy({ !$0.viewerCanUpdate }) { return updatePermissionReason }
    if items.allSatisfy({ $0.state != .open }) { return "Pull request is not open" }
    if items.allSatisfy({ $0.isDraft }) { return "Pull request is a draft" }
    if items.allSatisfy({ $0.mergeable == .conflicting }) {
      return "Merge conflicts must be resolved before merging"
    }
    return "Nothing in this selection is ready to merge"
  }

  static func rerunReason(for items: [ReviewItem]) -> String? {
    if items.isEmpty { return "No pull requests selected" }
    if items.contains(where: { $0.canAttemptRerunChecks }) { return nil }
    if items.allSatisfy({ !$0.viewerCanUpdate }) { return updatePermissionReason }
    if items.allSatisfy({ $0.checkStatus == .success }) {
      return "All checks passing - nothing to rerun"
    }
    if items.allSatisfy({ $0.checkStatus == .pending }) {
      return "Checks are still running"
    }
    return "No failed or timed-out check suites to rerun"
  }

  static func autoReason(for items: [ReviewItem]) -> String? {
    if items.isEmpty { return "No pull requests selected" }
    if items.contains(where: { $0.canRunAutoMode }) { return nil }
    if items.allSatisfy({ !$0.viewerCanUpdate }) { return updatePermissionReason }
    return "Nothing in this selection matches the auto-mode rules"
  }

  static func labelReason(for items: [ReviewItem]) -> String? {
    if items.isEmpty { return "No pull requests selected" }
    if items.contains(where: { $0.canAddReviewLabel }) { return nil }
    if items.allSatisfy({ !$0.viewerCanUpdate }) { return updatePermissionReason }
    if items.allSatisfy({ $0.state != .open }) { return "Pull request is not open" }
    return "No selected pull request can be labeled"
  }

  static func rebaseReason(for item: ReviewItem) -> String? {
    if item.canRebaseViaBot { return nil }
    if !item.viewerCanUpdate { return updatePermissionReason }
    if item.state != .open { return "Pull request is not open" }
    return "This pull request cannot be rebased from the dashboard"
  }

  static func emptySelectionReason(for items: [ReviewItem]) -> String? {
    items.isEmpty ? "No pull requests selected" : nil
  }

  static func autoPreview(for items: [ReviewItem]) -> String? {
    guard items.count > 1 else { return nil }
    let eligibleCount = items.count { $0.isAutoApprovable || $0.isAutoMergeable }
    let approveCount = items.count { $0.isAutoApprovable }
    let mergeCount = items.count { $0.isAutoMergeable }
    let skipCount = items.count - eligibleCount
    if eligibleCount == 0 {
      return "No PRs in this selection match the auto-mode rules"
    }
    return "Will approve \(approveCount), merge \(mergeCount), skip \(skipCount)"
  }

  private static var updatePermissionReason: String {
    "Current GitHub token cannot update selected pull request(s)"
  }
}
