import HarnessMonitorKit
import SwiftUI

struct DashboardReviewsStatusOrderKey: Comparable {
  let bucket: Int
  let reviewTier: Int
  let checkTier: Int
  let updatedAt: String
  let number: UInt64

  static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.bucket != rhs.bucket { return lhs.bucket < rhs.bucket }
    if lhs.reviewTier != rhs.reviewTier { return lhs.reviewTier < rhs.reviewTier }
    if lhs.checkTier != rhs.checkTier { return lhs.checkTier < rhs.checkTier }
    if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
    return lhs.number < rhs.number
  }
}

extension ReviewItem {
  var statusOrderKey: DashboardReviewsStatusOrderKey {
    DashboardReviewsStatusOrderKey(
      bucket: statusBucket,
      reviewTier: reviewStatus.orderTier,
      checkTier: checkStatus.orderTier,
      updatedAt: updatedAt,
      number: number
    )
  }

  fileprivate var statusBucket: Int {
    if isDraft { return 10 }
    if isAutoMergeable { return 0 }
    if isAutoApprovable { return 1 }
    if reviewStatus == .approved { return 2 }
    if checkStatus == .pending { return 3 }
    if reviewStatus == .reviewRequired { return 4 }
    if reviewStatus == .changesRequested { return 5 }
    if checkStatus == .failure { return 6 }
    if mergeable == .conflicting { return 7 }
    if policyBlocked { return 8 }
    return 9
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

extension ReviewReviewStatus {
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

  var orderTier: Int {
    switch self {
    case .approved: 0
    case .reviewRequired: 1
    case .changesRequested: 2
    case .none: 3
    case .unknown: 4
    }
  }
}

extension ReviewCheckStatus {
  var label: String {
    switch self {
    case .none: "No checks"
    case .success: "Checks passing"
    case .failure: "Checks failing"
    case .pending: "Checks running"
    case .unknown(let raw): raw
    }
  }

  var orderTier: Int {
    switch self {
    case .success: 0
    case .pending: 1
    case .failure: 2
    case .none: 3
    case .unknown: 4
    }
  }
}

extension ReviewCheck {
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

extension ReviewCheckConclusion {
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

extension ReviewReviewEventState {
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

extension Array where Element == String {
  func removingDuplicates() -> [String] {
    var seen = Set<String>()
    return filter { seen.insert($0).inserted }
  }
}
