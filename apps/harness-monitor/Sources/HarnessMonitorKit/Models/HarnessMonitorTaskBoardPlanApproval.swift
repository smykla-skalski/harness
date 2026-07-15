import Foundation

/// Planning-lifecycle approval state derived from a board item's stored
/// `TaskBoardPlanningState`. The daemon does not send a discrete enum; the
/// three states fall out of which planning fields are populated, so the
/// derivation lives here where it can be exercised without the view layer.
public enum TaskBoardPlanApprovalState: String, Equatable, Sendable {
  case notApproved
  case submitted
  case approved

  public init(planning: TaskBoardPlanningState) {
    if let approvedBy = planning.approvedBy, !approvedBy.isEmpty {
      self = .approved
    } else if let summary = planning.summary,
      !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      self = .submitted
    } else {
      self = .notApproved
    }
  }

  /// Compact label for the board-card pill.
  public var badgeLabel: String {
    switch self {
    case .notApproved:
      "Not approved"
    case .submitted:
      "Submitted"
    case .approved:
      "Approved"
    }
  }

  /// Fuller label for VoiceOver, where the "plan" noun is not implied by
  /// the surrounding card context.
  public var accessibilityLabel: String {
    switch self {
    case .notApproved:
      "Plan not approved"
    case .submitted:
      "Plan submitted"
    case .approved:
      "Plan approved"
    }
  }
}

extension TaskBoardItem {
  public var planApprovalState: TaskBoardPlanApprovalState {
    TaskBoardPlanApprovalState(planning: planning)
  }
}
