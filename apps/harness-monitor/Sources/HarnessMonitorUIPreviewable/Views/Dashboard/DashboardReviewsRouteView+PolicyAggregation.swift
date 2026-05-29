import Foundation
import HarnessMonitorKit

/// Single source of truth for how one auto-policy outcome rolls up into the
/// multi-PR aggregate summary. Only `.completed` is a success; in-flight runs
/// (`.waiting`/`.running`) stay neutral; everything else - a transport error,
/// a `.failed`/`.cancelled`/`.unknown(_)` run, or a run that never started -
/// is needs-attention so the aggregate never shows an all-green success while
/// any run is unfinished.
enum DashboardReviewsPolicyAggregationClass: Equatable, Sendable {
  case completed
  case waiting
  case running
  case skipped
  case cancelled
  case failed
}

extension DashboardReviewsAutoPolicyOutcome {
  var policyAggregationClass: DashboardReviewsPolicyAggregationClass {
    if errorMessage != nil {
      return .failed
    }
    if skippedReason != nil {
      return .skipped
    }
    switch finalStatus {
    case .completed:
      return .completed
    case .waiting:
      return .waiting
    case .pending, .running:
      return .running
    case .cancelled:
      return .cancelled
    case .failed, .unknown, nil:
      return .failed
    }
  }
}
