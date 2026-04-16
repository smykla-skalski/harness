import Foundation

public enum SessionSortOrder: String, CaseIterable, Identifiable, Sendable {
  case recentActivity
  case name
  case status

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .recentActivity: "Recent Activity"
    case .name: "Name"
    case .status: "Status"
    }
  }

  func compare(_ lhs: SessionSummary, _ rhs: SessionSummary) -> Bool {
    switch self {
    case .recentActivity:
      lhs.updatedAt > rhs.updatedAt
    case .name:
      lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
    case .status:
      lhs.status.sortKey < rhs.status.sortKey
    }
  }
}

extension SessionStatus {
  var sortKey: Int {
    switch self {
    case .active: 0
    case .paused: 1
    case .ended: 2
    }
  }
}

public enum SessionFocusFilter: String, CaseIterable, Identifiable, Sendable {
  case all
  case openWork
  case blocked
  case observed
  case idle

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .all:
      "All"
    case .openWork:
      "Open Work"
    case .blocked:
      "Blocked"
    case .observed:
      "Observed"
    case .idle:
      "Idle"
    }
  }

  func includes(_ summary: SessionSummary) -> Bool {
    switch self {
    case .all:
      true
    case .openWork:
      summary.metrics.openTaskCount > 0 || summary.metrics.inProgressTaskCount > 0
    case .blocked:
      summary.metrics.blockedTaskCount > 0
    case .observed:
      summary.observeId != nil
    case .idle:
      summary.metrics.activeAgentCount == 0 && summary.metrics.openTaskCount == 0
    }
  }
}
