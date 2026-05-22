import HarnessMonitorKit

extension DependencyUpdateCheck {
  var displayPriority: Int {
    if status != .completed {
      return 1
    }
    switch conclusion {
    case .failure, .cancelled, .timedOut, .actionRequired, .startupFailure:
      return 0
    case .success:
      return 2
    case .none, .neutral, .skipped, .stale, .unknown:
      return 3
    }
  }

  var isPassing: Bool {
    status == .completed && conclusion == .success
  }

  var requiresAttention: Bool {
    status == .completed
      && [.failure, .cancelled, .timedOut, .actionRequired, .startupFailure].contains(conclusion)
  }

  var isNeutralStatus: Bool {
    switch conclusion {
    case .none, .neutral, .skipped, .stale, .unknown:
      true
    case .success, .failure, .cancelled, .timedOut, .actionRequired, .startupFailure:
      false
    }
  }

  var systemImage: String {
    switch status {
    case .completed:
      switch conclusion {
      case .success:
        "checkmark.circle.fill"
      case .failure, .cancelled, .timedOut, .actionRequired, .startupFailure:
        "xmark.octagon.fill"
      default:
        "circle"
      }
    case .inProgress:
      "arrow.triangle.2.circlepath"
    case .queued, .requested, .waiting:
      "clock"
    case .unknown:
      "questionmark.circle"
    }
  }
}
