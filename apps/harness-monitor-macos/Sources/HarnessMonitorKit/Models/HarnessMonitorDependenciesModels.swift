import Foundation

public struct DependencyUpdatesQueryRequest: Codable, Equatable, Sendable {
  public let authors: [String]
  public let organizations: [String]
  public let repositories: [String]
  public let excludeRepositories: [String]
  public let forceRefresh: Bool
  public let cacheMaxAgeSeconds: UInt64

  public init(
    authors: [String] = [],
    organizations: [String] = [],
    repositories: [String] = [],
    excludeRepositories: [String] = [],
    forceRefresh: Bool = false,
    cacheMaxAgeSeconds: UInt64 = 600
  ) {
    self.authors = authors
    self.organizations = organizations
    self.repositories = repositories
    self.excludeRepositories = excludeRepositories
    self.forceRefresh = forceRefresh
    self.cacheMaxAgeSeconds = cacheMaxAgeSeconds
  }
}

public struct DependencyUpdatesApproveRequest: Codable, Equatable, Sendable {
  public let targets: [DependencyUpdateTarget]

  public init(targets: [DependencyUpdateTarget]) {
    self.targets = targets
  }
}

public struct DependencyUpdatesMergeRequest: Codable, Equatable, Sendable {
  public let targets: [DependencyUpdateTarget]
  public let method: TaskBoardGitHubMergeMethod

  public init(
    targets: [DependencyUpdateTarget],
    method: TaskBoardGitHubMergeMethod = .squash
  ) {
    self.targets = targets
    self.method = method
  }
}

public struct DependencyUpdatesRerunChecksRequest: Codable, Equatable, Sendable {
  public let targets: [DependencyUpdateTarget]

  public init(targets: [DependencyUpdateTarget]) {
    self.targets = targets
  }
}

public struct DependencyUpdatesLabelRequest: Codable, Equatable, Sendable {
  public let targets: [DependencyUpdateTarget]
  public let label: String

  public init(targets: [DependencyUpdateTarget], label: String) {
    self.targets = targets
    self.label = label
  }
}

public struct DependencyUpdatesAutoRequest: Codable, Equatable, Sendable {
  public let targets: [DependencyUpdateTarget]
  public let method: TaskBoardGitHubMergeMethod

  public init(
    targets: [DependencyUpdateTarget],
    method: TaskBoardGitHubMergeMethod = .squash
  ) {
    self.targets = targets
    self.method = method
  }
}

public struct DependencyUpdatesQueryResponse: Codable, Equatable, Sendable {
  public let fetchedAt: String
  public let fromCache: Bool
  public let summary: DependencyUpdatesSummary
  public let items: [DependencyUpdateItem]

  public init(
    fetchedAt: String,
    fromCache: Bool,
    summary: DependencyUpdatesSummary,
    items: [DependencyUpdateItem]
  ) {
    self.fetchedAt = fetchedAt
    self.fromCache = fromCache
    self.summary = summary
    self.items = items
  }
}

public struct DependencyUpdatesSummary: Codable, Equatable, Sendable {
  public let total: Int
  public let reviewRequired: Int
  public let readyToMerge: Int
  public let autoApprovable: Int
  public let waitingOnChecks: Int
  public let blocked: Int

  public init(
    total: Int,
    reviewRequired: Int,
    readyToMerge: Int,
    autoApprovable: Int,
    waitingOnChecks: Int,
    blocked: Int
  ) {
    self.total = total
    self.reviewRequired = reviewRequired
    self.readyToMerge = readyToMerge
    self.autoApprovable = autoApprovable
    self.waitingOnChecks = waitingOnChecks
    self.blocked = blocked
  }

  public init(items: [DependencyUpdateItem]) {
    total = items.count
    reviewRequired = items.count { $0.reviewStatus == .reviewRequired }
    readyToMerge = items.count { $0.isAutoMergeable }
    autoApprovable = items.count { $0.isAutoApprovable }
    waitingOnChecks = items.count { $0.checkStatus == .pending }
    blocked = items.count { $0.requiresAttention }
  }
}

public struct DependencyUpdateItem: Codable, Equatable, Identifiable, Sendable {
  public let pullRequestID: String
  public let repositoryID: String
  public let repository: String
  public let number: UInt64
  public let title: String
  public let url: String
  public let authorLogin: String
  public let state: DependencyUpdatePullRequestState
  public let mergeable: DependencyUpdateMergeableState
  public let reviewStatus: DependencyUpdateReviewStatus
  public let checkStatus: DependencyUpdateCheckStatus
  public let policyBlocked: Bool
  public let isDraft: Bool
  public let headSha: String
  public let labels: [String]
  public let checks: [DependencyUpdateCheck]
  public let reviews: [DependencyUpdateReview]
  public let additions: UInt64
  public let deletions: UInt64
  public let createdAt: String
  public let updatedAt: String

  public var id: String { pullRequestID }

  public init(
    pullRequestID: String,
    repositoryID: String,
    repository: String,
    number: UInt64,
    title: String,
    url: String,
    authorLogin: String,
    state: DependencyUpdatePullRequestState,
    mergeable: DependencyUpdateMergeableState,
    reviewStatus: DependencyUpdateReviewStatus,
    checkStatus: DependencyUpdateCheckStatus,
    policyBlocked: Bool,
    isDraft: Bool,
    headSha: String,
    labels: [String] = [],
    checks: [DependencyUpdateCheck] = [],
    reviews: [DependencyUpdateReview] = [],
    additions: UInt64,
    deletions: UInt64,
    createdAt: String,
    updatedAt: String
  ) {
    self.pullRequestID = pullRequestID
    self.repositoryID = repositoryID
    self.repository = repository
    self.number = number
    self.title = title
    self.url = url
    self.authorLogin = authorLogin
    self.state = state
    self.mergeable = mergeable
    self.reviewStatus = reviewStatus
    self.checkStatus = checkStatus
    self.policyBlocked = policyBlocked
    self.isDraft = isDraft
    self.headSha = headSha
    self.labels = labels
    self.checks = checks
    self.reviews = reviews
    self.additions = additions
    self.deletions = deletions
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  enum CodingKeys: String, CodingKey {
    case pullRequestID = "pullRequestId"
    case repositoryID = "repositoryId"
    case repository
    case number
    case title
    case url
    case authorLogin
    case state
    case mergeable
    case reviewStatus
    case checkStatus
    case policyBlocked
    case isDraft
    case headSha
    case labels
    case checks
    case reviews
    case additions
    case deletions
    case createdAt
    case updatedAt
  }
}

public struct DependencyUpdateCheck: Codable, Equatable, Identifiable, Sendable {
  public let name: String
  public let status: DependencyUpdateCheckRunStatus
  public let conclusion: DependencyUpdateCheckConclusion
  public let checkSuiteID: String?

  public var id: String { "\(name)-\(checkSuiteID ?? "none")" }

  public init(
    name: String,
    status: DependencyUpdateCheckRunStatus,
    conclusion: DependencyUpdateCheckConclusion,
    checkSuiteID: String? = nil
  ) {
    self.name = name
    self.status = status
    self.conclusion = conclusion
    self.checkSuiteID = checkSuiteID
  }

  enum CodingKeys: String, CodingKey {
    case name
    case status
    case conclusion
    case checkSuiteID = "checkSuiteId"
  }
}

public struct DependencyUpdateReview: Codable, Equatable, Identifiable, Sendable {
  public let author: String
  public let state: DependencyUpdateReviewEventState

  public var id: String { "\(author)-\(state.rawValue)" }

  public init(author: String, state: DependencyUpdateReviewEventState) {
    self.author = author
    self.state = state
  }
}

public struct DependencyUpdateTarget: Codable, Equatable, Sendable {
  public let pullRequestID: String
  public let repositoryID: String
  public let repository: String
  public let number: UInt64
  public let url: String
  public let headSha: String
  public let mergeable: DependencyUpdateMergeableState
  public let reviewStatus: DependencyUpdateReviewStatus
  public let checkStatus: DependencyUpdateCheckStatus
  public let policyBlocked: Bool
  public let checkSuiteIDs: [String]

  public init(
    pullRequestID: String,
    repositoryID: String,
    repository: String,
    number: UInt64,
    url: String,
    headSha: String,
    mergeable: DependencyUpdateMergeableState,
    reviewStatus: DependencyUpdateReviewStatus,
    checkStatus: DependencyUpdateCheckStatus,
    policyBlocked: Bool,
    checkSuiteIDs: [String] = []
  ) {
    self.pullRequestID = pullRequestID
    self.repositoryID = repositoryID
    self.repository = repository
    self.number = number
    self.url = url
    self.headSha = headSha
    self.mergeable = mergeable
    self.reviewStatus = reviewStatus
    self.checkStatus = checkStatus
    self.policyBlocked = policyBlocked
    self.checkSuiteIDs = checkSuiteIDs
  }

  enum CodingKeys: String, CodingKey {
    case pullRequestID = "pullRequestId"
    case repositoryID = "repositoryId"
    case repository
    case number
    case url
    case headSha
    case mergeable
    case reviewStatus
    case checkStatus
    case policyBlocked
    case checkSuiteIDs = "checkSuiteIds"
  }
}

public struct DependencyUpdatesActionResponse: Codable, Equatable, Sendable {
  public let summary: String
  public let results: [DependencyUpdateActionResult]

  public init(summary: String, results: [DependencyUpdateActionResult] = []) {
    self.summary = summary
    self.results = results
  }
}

public struct DependencyUpdateActionResult: Codable, Equatable, Sendable {
  public let repository: String
  public let number: UInt64
  public let action: DependencyUpdateActionKind
  public let outcome: DependencyUpdateActionOutcome
  public let message: String?

  public init(
    repository: String,
    number: UInt64,
    action: DependencyUpdateActionKind,
    outcome: DependencyUpdateActionOutcome,
    message: String? = nil
  ) {
    self.repository = repository
    self.number = number
    self.action = action
    self.outcome = outcome
    self.message = message
  }
}

public struct DependencyUpdatesCacheClearResponse: Codable, Equatable, Sendable {
  public let clearedEntries: Int

  public init(clearedEntries: Int) {
    self.clearedEntries = clearedEntries
  }
}

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

  public static let allCases: [Self] = [.none, .success, .failure, .neutral, .cancelled, .timedOut, .actionRequired, .skipped, .stale, .startupFailure]
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

  public init(rawValue: String) {
    switch rawValue {
    case "none": self = .none
    case "success": self = .success
    case "failure": self = .failure
    case "neutral": self = .neutral
    case "cancelled": self = .cancelled
    case "timed_out": self = .timedOut
    case "action_required": self = .actionRequired
    case "skipped": self = .skipped
    case "stale": self = .stale
    case "startup_failure": self = .startupFailure
    default: self = .unknown(rawValue)
    }
  }
}

public enum DependencyUpdateReviewEventState: TaskBoardOpenEnum, CaseIterable, Identifiable {
  case approved
  case changesRequested
  case commented
  case dismissed
  case pending
  case unknown(String)

  public static let allCases: [Self] = [.approved, .changesRequested, .commented, .dismissed, .pending]
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

  public static let allCases: [Self] = [.approve, .merge, .rerunChecks, .addLabel, .autoApprove, .autoMerge]
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

extension DependencyUpdateItem {
  public var target: DependencyUpdateTarget {
    DependencyUpdateTarget(
      pullRequestID: pullRequestID,
      repositoryID: repositoryID,
      repository: repository,
      number: number,
      url: url,
      headSha: headSha,
      mergeable: mergeable,
      reviewStatus: reviewStatus,
      checkStatus: checkStatus,
      policyBlocked: policyBlocked,
      checkSuiteIDs: checks.compactMap(\.checkSuiteID)
    )
  }

  public var rerunTarget: DependencyUpdateTarget {
    DependencyUpdateTarget(
      pullRequestID: pullRequestID,
      repositoryID: repositoryID,
      repository: repository,
      number: number,
      url: url,
      headSha: headSha,
      mergeable: mergeable,
      reviewStatus: reviewStatus,
      checkStatus: checkStatus,
      policyBlocked: policyBlocked,
      checkSuiteIDs: rerunnableCheckSuiteIDs
    )
  }

  public var rerunnableCheckSuiteIDs: [String] {
    var seen = Set<String>()
    return checks.compactMap { check in
      guard check.isRerunnable, let checkSuiteID = check.checkSuiteID else {
        return nil
      }
      guard seen.insert(checkSuiteID).inserted else {
        return nil
      }
      return checkSuiteID
    }
  }

  public var hasRerunnableChecks: Bool {
    !rerunnableCheckSuiteIDs.isEmpty
  }

  public var canAttemptManualApproval: Bool {
    state == .open && reviewStatus == .reviewRequired
  }

  public var canAttemptManualMerge: Bool {
    state == .open && !isDraft && mergeable != .conflicting
  }

  public var canRunAutoMode: Bool {
    isAutoApprovable || isAutoMergeable
  }

  public var canStartFixCI: Bool {
    checkStatus == .failure
  }

  public var isAutoApprovable: Bool {
    target.isAutoApprovable
  }

  public var isAutoMergeable: Bool {
    target.isAutoMergeable
  }

  public var requiresAttention: Bool {
    policyBlocked
      || mergeable == .conflicting
      || reviewStatus == .changesRequested
      || checkStatus == .failure
  }
}

extension DependencyUpdateCheck {
  public var isRerunnable: Bool {
    guard checkSuiteID != nil, status == .completed else {
      return false
    }
    switch conclusion {
    case .failure, .timedOut:
      return true
    default:
      return false
    }
  }
}

extension DependencyUpdateTarget {
  public var isAutoApprovable: Bool {
    checkStatus == .success
      && reviewStatus == .reviewRequired
      && mergeable != .conflicting
  }

  public var isAutoMergeable: Bool {
    reviewStatus == .approved
      && checkStatus == .success
      && mergeable != .conflicting
      && !policyBlocked
  }
}

extension DependencyUpdateItem {
  public func replacing(
    state: DependencyUpdatePullRequestState? = nil,
    reviewStatus: DependencyUpdateReviewStatus? = nil,
    checkStatus: DependencyUpdateCheckStatus? = nil,
    labels: [String]? = nil,
    checks: [DependencyUpdateCheck]? = nil,
    policyBlocked: Bool? = nil
  ) -> Self {
    DependencyUpdateItem(
      pullRequestID: pullRequestID,
      repositoryID: repositoryID,
      repository: repository,
      number: number,
      title: title,
      url: url,
      authorLogin: authorLogin,
      state: state ?? self.state,
      mergeable: mergeable,
      reviewStatus: reviewStatus ?? self.reviewStatus,
      checkStatus: checkStatus ?? self.checkStatus,
      policyBlocked: policyBlocked ?? self.policyBlocked,
      isDraft: isDraft,
      headSha: headSha,
      labels: labels ?? self.labels,
      checks: checks ?? self.checks,
      reviews: reviews,
      additions: additions,
      deletions: deletions,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }
}
