import SwiftUI

public struct DashboardReviewsCommandFocus: Equatable, @unchecked Sendable {
  public let selectionCount: Int
  public let hasProblemChecksFilter: Bool
  public let canApprove: Bool
  public let canMerge: Bool
  public let canRerunChecks: Bool
  public let canOpenPullRequest: Bool
  public let canCopyDiagnostics: Bool
  public let canTogglePinSelection: Bool
  public let pinSelectionTitle: String
  public let approve: () -> Void
  public let merge: () -> Void
  public let rerunChecks: () -> Void
  public let openPullRequest: () -> Void
  public let copyDiagnostics: () -> Void
  public let togglePinSelection: () -> Void
  public let toggleProblemChecksFilter: () -> Void

  public init(
    selectionCount: Int,
    hasProblemChecksFilter: Bool,
    canApprove: Bool,
    canMerge: Bool,
    canRerunChecks: Bool,
    canOpenPullRequest: Bool,
    canCopyDiagnostics: Bool,
    canTogglePinSelection: Bool,
    pinSelectionTitle: String,
    approve: @escaping () -> Void,
    merge: @escaping () -> Void,
    rerunChecks: @escaping () -> Void,
    openPullRequest: @escaping () -> Void,
    copyDiagnostics: @escaping () -> Void,
    togglePinSelection: @escaping () -> Void,
    toggleProblemChecksFilter: @escaping () -> Void
  ) {
    self.selectionCount = selectionCount
    self.hasProblemChecksFilter = hasProblemChecksFilter
    self.canApprove = canApprove
    self.canMerge = canMerge
    self.canRerunChecks = canRerunChecks
    self.canOpenPullRequest = canOpenPullRequest
    self.canCopyDiagnostics = canCopyDiagnostics
    self.canTogglePinSelection = canTogglePinSelection
    self.pinSelectionTitle = pinSelectionTitle
    self.approve = approve
    self.merge = merge
    self.rerunChecks = rerunChecks
    self.openPullRequest = openPullRequest
    self.copyDiagnostics = copyDiagnostics
    self.togglePinSelection = togglePinSelection
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
      && lhs.canTogglePinSelection == rhs.canTogglePinSelection
      && lhs.pinSelectionTitle == rhs.pinSelectionTitle
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
