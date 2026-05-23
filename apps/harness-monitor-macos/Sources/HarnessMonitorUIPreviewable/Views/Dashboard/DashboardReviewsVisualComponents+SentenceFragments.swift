import HarnessMonitorKit

extension ReviewReviewStatus {
  var statusSentenceFragment: String {
    switch self {
    case .approved:
      "approved review"
    case .reviewRequired:
      "review required"
    case .changesRequested:
      "changes requested"
    case .none:
      "no review submitted"
    case .unknown(let raw):
      "review state \(raw)"
    }
  }
}

extension ReviewCheckStatus {
  var statusSentenceFragment: String {
    switch self {
    case .success:
      "checks passing"
    case .failure:
      "checks failing"
    case .pending:
      "checks still running"
    case .none:
      "no checks reported"
    case .unknown(let raw):
      "check state \(raw)"
    }
  }
}
