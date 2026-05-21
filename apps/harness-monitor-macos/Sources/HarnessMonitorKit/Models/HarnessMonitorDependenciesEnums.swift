import Foundation

public enum DependencyUpdatePullRequestState: TaskBoardOpenEnum, CaseIterable, Identifiable {
  case open
  case closed
  case merged
  case unknown(String)

  public static let allCases: [Self] = [.open, .closed, .merged]
  public var id: String { rawValue }

  public var rawValue: String {
    switch self {
    case .open: "open"
    case .closed: "closed"
    case .merged: "merged"
    case .unknown(let raw): raw
    }
  }

  public init(rawValue: String) {
    switch rawValue {
    case "open": self = .open
    case "closed": self = .closed
    case "merged": self = .merged
    default: self = .unknown(rawValue)
    }
  }
}

public enum DependencyUpdateMergeableState: TaskBoardOpenEnum, CaseIterable, Identifiable {
  case mergeable
  case conflicting
  case unknown(String)

  public static let allCases: [Self] = [.mergeable, .conflicting]
  public var id: String { rawValue }

  public var rawValue: String {
    switch self {
    case .mergeable: "mergeable"
    case .conflicting: "conflicting"
    case .unknown(let raw): raw
    }
  }

  public init(rawValue: String) {
    switch rawValue {
    case "mergeable": self = .mergeable
    case "conflicting": self = .conflicting
    default: self = .unknown(rawValue)
    }
  }
}

public enum DependencyUpdateReviewStatus: TaskBoardOpenEnum, CaseIterable, Identifiable {
  case none
  case reviewRequired
  case approved
  case changesRequested
  case unknown(String)

  public static let allCases: [Self] = [.none, .reviewRequired, .approved, .changesRequested]
  public var id: String { rawValue }

  public var rawValue: String {
    switch self {
    case .none: "none"
    case .reviewRequired: "review_required"
    case .approved: "approved"
    case .changesRequested: "changes_requested"
    case .unknown(let raw): raw
    }
  }

  public init(rawValue: String) {
    switch rawValue {
    case "none": self = .none
    case "review_required": self = .reviewRequired
    case "approved": self = .approved
    case "changes_requested": self = .changesRequested
    default: self = .unknown(rawValue)
    }
  }
}

public enum DependencyUpdateCheckStatus: TaskBoardOpenEnum, CaseIterable, Identifiable {
  case none
  case success
  case failure
  case pending
  case unknown(String)

  public static let allCases: [Self] = [.none, .success, .failure, .pending]
  public var id: String { rawValue }

  public var rawValue: String {
    switch self {
    case .none: "none"
    case .success: "success"
    case .failure: "failure"
    case .pending: "pending"
    case .unknown(let raw): raw
    }
  }

  public init(rawValue: String) {
    switch rawValue {
    case "none": self = .none
    case "success": self = .success
    case "failure": self = .failure
    case "pending": self = .pending
    default: self = .unknown(rawValue)
    }
  }
}

public enum DependencyUpdateCheckRunStatus: TaskBoardOpenEnum, CaseIterable, Identifiable {
  case completed
  case inProgress
  case queued
  case requested
  case waiting
  case unknown(String)

  public static let allCases: [Self] = [.completed, .inProgress, .queued, .requested, .waiting]
  public var id: String { rawValue }

  public var rawValue: String {
    switch self {
    case .completed: "completed"
    case .inProgress: "in_progress"
    case .queued: "queued"
    case .requested: "requested"
    case .waiting: "waiting"
    case .unknown(let raw): raw
    }
  }

  public init(rawValue: String) {
    switch rawValue {
    case "completed": self = .completed
    case "in_progress": self = .inProgress
    case "queued": self = .queued
    case "requested": self = .requested
    case "waiting": self = .waiting
    default: self = .unknown(rawValue)
    }
  }
}

public enum DependencyUpdateCheckConclusion: TaskBoardOpenEnum, CaseIterable, Identifiable {
  case none
  case success
  case failure
  case neutral
  case cancelled
  case timedOut
  case actionRequired
  case skipped
  case stale
  case startupFailure
  case unknown(String)

  public static let allCases: [Self] = [
    .none, .success, .failure, .neutral, .cancelled, .timedOut, .actionRequired, .skipped, .stale,
    .startupFailure,
  ]
  public var id: String { rawValue }

  public var rawValue: String {
    switch self {
    case .none: "none"
    case .success: "success"
    case .failure: "failure"
    case .neutral: "neutral"
    case .cancelled: "cancelled"
    case .timedOut: "timed_out"
    case .actionRequired: "action_required"
    case .skipped: "skipped"
    case .stale: "stale"
    case .startupFailure: "startup_failure"
    case .unknown(let raw): raw
    }
  }

  private static let knownCases: [String: Self] = [
    "none": .none,
    "success": .success,
    "failure": .failure,
    "neutral": .neutral,
    "cancelled": .cancelled,
    "timed_out": .timedOut,
    "action_required": .actionRequired,
    "skipped": .skipped,
    "stale": .stale,
    "startup_failure": .startupFailure,
  ]

  public init(rawValue: String) {
    self = Self.knownCases[rawValue] ?? .unknown(rawValue)
  }
}

public enum DependencyUpdateReviewEventState: TaskBoardOpenEnum, CaseIterable, Identifiable {
  case approved
  case changesRequested
  case commented
  case dismissed
  case pending
  case unknown(String)

  public static let allCases: [Self] = [
    .approved, .changesRequested, .commented, .dismissed, .pending,
  ]
  public var id: String { rawValue }

  public var rawValue: String {
    switch self {
    case .approved: "approved"
    case .changesRequested: "changes_requested"
    case .commented: "commented"
    case .dismissed: "dismissed"
    case .pending: "pending"
    case .unknown(let raw): raw
    }
  }

  public init(rawValue: String) {
    switch rawValue {
    case "approved": self = .approved
    case "changes_requested": self = .changesRequested
    case "commented": self = .commented
    case "dismissed": self = .dismissed
    case "pending": self = .pending
    default: self = .unknown(rawValue)
    }
  }
}

public enum DependencyUpdateActionKind: TaskBoardOpenEnum, CaseIterable, Identifiable {
  case approve
  case merge
  case rerunChecks
  case addLabel
  case autoApprove
  case autoMerge
  case unknown(String)

  public static let allCases: [Self] = [
    .approve, .merge, .rerunChecks, .addLabel, .autoApprove, .autoMerge,
  ]
  public var id: String { rawValue }

  public var rawValue: String {
    switch self {
    case .approve: "approve"
    case .merge: "merge"
    case .rerunChecks: "rerun_checks"
    case .addLabel: "add_label"
    case .autoApprove: "auto_approve"
    case .autoMerge: "auto_merge"
    case .unknown(let raw): raw
    }
  }

  public init(rawValue: String) {
    switch rawValue {
    case "approve": self = .approve
    case "merge": self = .merge
    case "rerun_checks": self = .rerunChecks
    case "add_label": self = .addLabel
    case "auto_approve": self = .autoApprove
    case "auto_merge": self = .autoMerge
    default: self = .unknown(rawValue)
    }
  }
}

public enum DependencyUpdateActionOutcome: TaskBoardOpenEnum, CaseIterable, Identifiable {
  case applied
  case skipped
  case failed
  case unknown(String)

  public static let allCases: [Self] = [.applied, .skipped, .failed]
  public var id: String { rawValue }

  public var rawValue: String {
    switch self {
    case .applied: "applied"
    case .skipped: "skipped"
    case .failed: "failed"
    case .unknown(let raw): raw
    }
  }

  public init(rawValue: String) {
    switch rawValue {
    case "applied": self = .applied
    case "skipped": self = .skipped
    case "failed": self = .failed
    default: self = .unknown(rawValue)
    }
  }
}
