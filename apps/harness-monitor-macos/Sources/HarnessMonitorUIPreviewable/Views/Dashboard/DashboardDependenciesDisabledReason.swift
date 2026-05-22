import HarnessMonitorKit

enum DashboardDependenciesDisabledReason {
  static func approveReason(for items: [DependencyUpdateItem]) -> String? {
    if items.isEmpty { return "No pull requests selected" }
    if items.contains(where: { $0.canAttemptManualApproval }) { return nil }
    if items.allSatisfy({ $0.state != .open }) { return "Pull request is not open" }
    if items.allSatisfy({ $0.reviewStatus == .approved }) { return "Already approved" }
    if items.allSatisfy({ $0.reviewStatus == .changesRequested }) {
      return "Changes requested — resolve review before approving"
    }
    return "Nothing in this selection needs approval"
  }

  static func mergeReason(for items: [DependencyUpdateItem]) -> String? {
    if items.isEmpty { return "No pull requests selected" }
    if items.contains(where: { $0.canAttemptManualMerge }) { return nil }
    if items.allSatisfy({ $0.state != .open }) { return "Pull request is not open" }
    if items.allSatisfy({ $0.isDraft }) { return "Pull request is a draft" }
    if items.allSatisfy({ $0.mergeable == .conflicting }) {
      return "Merge conflicts must be resolved before merging"
    }
    return "Nothing in this selection is ready to merge"
  }

  static func rerunReason(for items: [DependencyUpdateItem]) -> String? {
    if items.isEmpty { return "No pull requests selected" }
    if items.contains(where: { $0.hasRerunnableChecks }) { return nil }
    if items.allSatisfy({ $0.checkStatus == .success }) {
      return "All checks passing — nothing to rerun"
    }
    if items.allSatisfy({ $0.checkStatus == .pending }) {
      return "Checks are still running"
    }
    return "No failed or timed-out check suites to rerun"
  }

  static func autoReason(for items: [DependencyUpdateItem]) -> String? {
    if items.isEmpty { return "No pull requests selected" }
    if items.contains(where: { $0.canRunAutoMode }) { return nil }
    return "Nothing in this selection matches the auto-mode rules"
  }

  static func emptySelectionReason(for items: [DependencyUpdateItem]) -> String? {
    items.isEmpty ? "No pull requests selected" : nil
  }

  static func autoPreview(for items: [DependencyUpdateItem]) -> String? {
    guard items.count > 1 else { return nil }
    let approveCount = items.filter(\.isAutoApprovable).count
    let mergeCount = items.filter { $0.isAutoMergeable || $0.isAutoApprovable }.count
    let skipCount = items.count - mergeCount
    if approveCount == 0 && mergeCount == 0 {
      return "No PRs in this selection match the auto-mode rules"
    }
    return
      "Will approve \(approveCount), merge \(mergeCount) "
      + "(includes the \(approveCount) just approved), skip \(skipCount)"
  }
}
