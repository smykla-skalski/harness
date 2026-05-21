import HarnessMonitorKit
import SwiftUI

extension DependencyUpdateItem {
  var statusWeight: Int {
    switch true {
    case reviewStatus == .approved && checkStatus == .success:
      0
    case checkStatus == .pending:
      1
    case reviewStatus == .reviewRequired:
      2
    case checkStatus == .failure:
      3
    case mergeable == .conflicting:
      4
    default:
      5
    }
  }

  var statusLabel: String {
    switch true {
    case isAutoMergeable: "Ready to merge"
    case isAutoApprovable: "Ready for approval"
    case checkStatus == .pending: "Checks running"
    case requiresAttention: "Needs attention"
    default: "Open"
    }
  }

  var statusTint: Color {
    switch true {
    case isAutoMergeable: HarnessMonitorTheme.success
    case isAutoApprovable: HarnessMonitorTheme.accent
    case checkStatus == .pending: HarnessMonitorTheme.caution
    case requiresAttention: HarnessMonitorTheme.danger
    default: HarnessMonitorTheme.secondaryInk
    }
  }

  var statusSystemImage: String {
    switch true {
    case isAutoMergeable: "checkmark.circle.fill"
    case isAutoApprovable: "checkmark.seal.fill"
    case checkStatus == .pending: "clock.arrow.circlepath"
    case requiresAttention: "exclamationmark.triangle.fill"
    default: "circle"
    }
  }

}

extension DependencyUpdateReviewStatus {
  var label: String {
    switch self {
    case .approved: "Approved"
    case .reviewRequired: "Review required"
    case .changesRequested: "Changes requested"
    case .none, .unknown: "No review"
    }
  }

  var tint: Color {
    switch self {
    case .approved: HarnessMonitorTheme.success
    case .reviewRequired: HarnessMonitorTheme.accent
    case .changesRequested: HarnessMonitorTheme.danger
    case .none, .unknown: HarnessMonitorTheme.secondaryInk
    }
  }
}

extension DependencyUpdateCheckStatus {
  var label: String {
    switch self {
    case .none: "No checks"
    case .success: "Checks passing"
    case .failure: "Checks failing"
    case .pending: "Checks pending"
    case .unknown(let raw): raw
    }
  }
}

extension DependencyUpdateCheck {
  var statusLabel: String {
    switch status {
    case .completed: conclusion.label
    case .inProgress: "In progress"
    case .queued: "Queued"
    case .requested: "Requested"
    case .waiting: "Waiting"
    case .unknown: status.rawValue
    }
  }

  var tint: Color {
    switch conclusion {
    case .success: HarnessMonitorTheme.success
    case .failure, .cancelled, .timedOut, .actionRequired, .startupFailure:
      HarnessMonitorTheme.danger
    case .none, .neutral, .skipped, .stale, .unknown:
      HarnessMonitorTheme.secondaryInk
    }
  }
}

extension DependencyUpdateCheckConclusion {
  var label: String {
    switch self {
    case .success: "Success"
    case .failure: "Failure"
    case .neutral: "Neutral"
    case .cancelled: "Cancelled"
    case .timedOut: "Timed out"
    case .actionRequired: "Action required"
    case .skipped: "Skipped"
    case .stale: "Stale"
    case .startupFailure: "Startup failure"
    case .none, .unknown: "Unknown"
    }
  }
}

extension DependencyUpdateReviewEventState {
  var label: String {
    switch self {
    case .approved: "Approved"
    case .changesRequested: "Changes requested"
    case .commented: "Commented"
    case .dismissed: "Dismissed"
    case .pending: "Pending"
    case .unknown: "Unknown"
    }
  }

  var tint: Color {
    switch self {
    case .approved: HarnessMonitorTheme.success
    case .changesRequested: HarnessMonitorTheme.danger
    case .commented, .dismissed, .pending, .unknown: HarnessMonitorTheme.secondaryInk
    }
  }
}

extension String {
  fileprivate var nonEmpty: String? {
    isEmpty ? nil : self
  }
}

extension Array where Element == String {
  func removingDuplicates() -> [String] {
    var seen = Set<String>()
    return filter { seen.insert($0).inserted }
  }
}
