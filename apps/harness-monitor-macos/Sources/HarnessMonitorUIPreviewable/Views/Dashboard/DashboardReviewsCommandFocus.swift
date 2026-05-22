import SwiftUI

public struct DashboardReviewsCommandFocus: Equatable, @unchecked Sendable {
  public let selectionCount: Int
  public let hasProblemChecksFilter: Bool
  public let canApprove: Bool
  public let canMerge: Bool
  public let canRerunChecks: Bool
  public let canOpenPullRequest: Bool
  public let canCopyDiagnostics: Bool
  public let approve: () -> Void
  public let merge: () -> Void
  public let rerunChecks: () -> Void
  public let openPullRequest: () -> Void
  public let copyDiagnostics: () -> Void
  public let toggleProblemChecksFilter: () -> Void

  public init(
    selectionCount: Int,
    hasProblemChecksFilter: Bool,
    canApprove: Bool,
    canMerge: Bool,
    canRerunChecks: Bool,
    canOpenPullRequest: Bool,
    canCopyDiagnostics: Bool,
    approve: @escaping () -> Void,
    merge: @escaping () -> Void,
    rerunChecks: @escaping () -> Void,
    openPullRequest: @escaping () -> Void,
    copyDiagnostics: @escaping () -> Void,
    toggleProblemChecksFilter: @escaping () -> Void
  ) {
    self.selectionCount = selectionCount
    self.hasProblemChecksFilter = hasProblemChecksFilter
    self.canApprove = canApprove
    self.canMerge = canMerge
    self.canRerunChecks = canRerunChecks
    self.canOpenPullRequest = canOpenPullRequest
    self.canCopyDiagnostics = canCopyDiagnostics
    self.approve = approve
    self.merge = merge
    self.rerunChecks = rerunChecks
    self.openPullRequest = openPullRequest
    self.copyDiagnostics = copyDiagnostics
    self.toggleProblemChecksFilter = toggleProblemChecksFilter
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.selectionCount == rhs.selectionCount
      && lhs.hasProblemChecksFilter == rhs.hasProblemChecksFilter
      && lhs.canApprove == rhs.canApprove
      && lhs.canMerge == rhs.canMerge
      && lhs.canRerunChecks == rhs.canRerunChecks
      && lhs.canOpenPullRequest == rhs.canOpenPullRequest
      && lhs.canCopyDiagnostics == rhs.canCopyDiagnostics
  }
}

private struct DashboardReviewsCommandFocusKey: FocusedValueKey {
  typealias Value = DashboardReviewsCommandFocus
}

extension FocusedValues {
  public var dashboardReviewsCommands: DashboardReviewsCommandFocus? {
    get { self[DashboardReviewsCommandFocusKey.self] }
    set { self[DashboardReviewsCommandFocusKey.self] = newValue }
  }
}
