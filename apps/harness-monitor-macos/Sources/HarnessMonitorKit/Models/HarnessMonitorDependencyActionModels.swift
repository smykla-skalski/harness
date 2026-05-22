import Foundation

public struct DependencyUpdateCheck: Codable, Equatable, Identifiable, Sendable {
  public let name: String
  public let status: DependencyUpdateCheckRunStatus
  public let conclusion: DependencyUpdateCheckConclusion
  public let checkSuiteID: String?
  public let detailsURL: String?

  public var id: String { "\(name)-\(checkSuiteID ?? "none")-\(detailsURL ?? "none")" }

  public init(
    name: String,
    status: DependencyUpdateCheckRunStatus,
    conclusion: DependencyUpdateCheckConclusion,
    checkSuiteID: String? = nil,
    detailsURL: String? = nil
  ) {
    self.name = name
    self.status = status
    self.conclusion = conclusion
    self.checkSuiteID = checkSuiteID
    self.detailsURL = detailsURL
  }

  enum CodingKeys: String, CodingKey {
    case name
    case status
    case conclusion
    case checkSuiteID = "checkSuiteId"
    case detailsURL = "detailsUrl"
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
  public let state: DependencyUpdatePullRequestState
  public let isDraft: Bool
  public let headSha: String
  public let mergeable: DependencyUpdateMergeableState
  public let reviewStatus: DependencyUpdateReviewStatus
  public let checkStatus: DependencyUpdateCheckStatus
  public let policyBlocked: Bool
  public let requiredFailedCheckNames: [String]
  public let viewerCanMergeAsAdmin: Bool
  public let checkSuiteIDs: [String]
  public let viewerCanUpdate: Bool

  public init(
    pullRequestID: String,
    repositoryID: String,
    repository: String,
    number: UInt64,
    url: String,
    state: DependencyUpdatePullRequestState = .open,
    isDraft: Bool = false,
    headSha: String,
    mergeable: DependencyUpdateMergeableState,
    reviewStatus: DependencyUpdateReviewStatus,
    checkStatus: DependencyUpdateCheckStatus,
    policyBlocked: Bool,
    requiredFailedCheckNames: [String] = [],
    viewerCanMergeAsAdmin: Bool = false,
    checkSuiteIDs: [String] = [],
    viewerCanUpdate: Bool = true
  ) {
    self.pullRequestID = pullRequestID
    self.repositoryID = repositoryID
    self.repository = repository
    self.number = number
    self.url = url
    self.state = state
    self.isDraft = isDraft
    self.headSha = headSha
    self.mergeable = mergeable
    self.reviewStatus = reviewStatus
    self.checkStatus = checkStatus
    self.policyBlocked = policyBlocked
    self.requiredFailedCheckNames = requiredFailedCheckNames
    self.viewerCanMergeAsAdmin = viewerCanMergeAsAdmin
    self.checkSuiteIDs = checkSuiteIDs
    self.viewerCanUpdate = viewerCanUpdate
  }

  enum CodingKeys: String, CodingKey {
    case pullRequestID = "pullRequestId"
    case repositoryID = "repositoryId"
    case repository
    case number
    case url
    case state
    case isDraft
    case headSha
    case mergeable
    case reviewStatus
    case checkStatus
    case policyBlocked
    case requiredFailedCheckNames
    case viewerCanMergeAsAdmin
    case checkSuiteIDs = "checkSuiteIds"
    case viewerCanUpdate
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    pullRequestID = try container.decode(String.self, forKey: .pullRequestID)
    repositoryID = try container.decode(String.self, forKey: .repositoryID)
    repository = try container.decode(String.self, forKey: .repository)
    number = try container.decode(UInt64.self, forKey: .number)
    url = try container.decode(String.self, forKey: .url)
    state =
      try container.decodeIfPresent(DependencyUpdatePullRequestState.self, forKey: .state) ?? .open
    isDraft = try container.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
    headSha = try container.decode(String.self, forKey: .headSha)
    mergeable = try container.decode(DependencyUpdateMergeableState.self, forKey: .mergeable)
    reviewStatus = try container.decode(DependencyUpdateReviewStatus.self, forKey: .reviewStatus)
    checkStatus = try container.decode(DependencyUpdateCheckStatus.self, forKey: .checkStatus)
    policyBlocked = try container.decode(Bool.self, forKey: .policyBlocked)
    requiredFailedCheckNames =
      try container.decodeIfPresent([String].self, forKey: .requiredFailedCheckNames) ?? []
    viewerCanMergeAsAdmin =
      try container.decodeIfPresent(Bool.self, forKey: .viewerCanMergeAsAdmin) ?? false
    checkSuiteIDs = try container.decodeIfPresent([String].self, forKey: .checkSuiteIDs) ?? []
    viewerCanUpdate = try container.decodeIfPresent(Bool.self, forKey: .viewerCanUpdate) ?? true
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(pullRequestID, forKey: .pullRequestID)
    try container.encode(repositoryID, forKey: .repositoryID)
    try container.encode(repository, forKey: .repository)
    try container.encode(number, forKey: .number)
    try container.encode(url, forKey: .url)
    if state != .open {
      try container.encode(state, forKey: .state)
    }
    if isDraft {
      try container.encode(isDraft, forKey: .isDraft)
    }
    try container.encode(headSha, forKey: .headSha)
    try container.encode(mergeable, forKey: .mergeable)
    try container.encode(reviewStatus, forKey: .reviewStatus)
    try container.encode(checkStatus, forKey: .checkStatus)
    try container.encode(policyBlocked, forKey: .policyBlocked)
    if !requiredFailedCheckNames.isEmpty {
      try container.encode(requiredFailedCheckNames, forKey: .requiredFailedCheckNames)
    }
    if viewerCanMergeAsAdmin {
      try container.encode(viewerCanMergeAsAdmin, forKey: .viewerCanMergeAsAdmin)
    }
    try container.encode(checkSuiteIDs, forKey: .checkSuiteIDs)
    if !viewerCanUpdate {
      try container.encode(viewerCanUpdate, forKey: .viewerCanUpdate)
    }
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
  public let timelineEntry: DependencyUpdateTimelineEntry?

  public init(
    repository: String,
    number: UInt64,
    action: DependencyUpdateActionKind,
    outcome: DependencyUpdateActionOutcome,
    message: String? = nil,
    timelineEntry: DependencyUpdateTimelineEntry? = nil
  ) {
    self.repository = repository
    self.number = number
    self.action = action
    self.outcome = outcome
    self.message = message
    self.timelineEntry = timelineEntry
  }
}

public struct DependencyUpdatesCacheClearResponse: Codable, Equatable, Sendable {
  public let clearedEntries: Int

  public init(clearedEntries: Int) {
    self.clearedEntries = clearedEntries
  }
}

public struct DependencyUpdatesRefreshRequest: Codable, Equatable, Sendable {
  public let targets: [DependencyUpdateTarget]

  public init(targets: [DependencyUpdateTarget]) {
    self.targets = targets
  }
}

public struct DependencyUpdatesRefreshResponse: Codable, Equatable, Sendable {
  public let fetchedAt: String
  public let items: [DependencyUpdateItem]
  public let missingPullRequestIDs: [String]

  public init(
    fetchedAt: String,
    items: [DependencyUpdateItem] = [],
    missingPullRequestIDs: [String] = []
  ) {
    self.fetchedAt = fetchedAt
    self.items = normalizedDependencyUpdateItems(items)
    self.missingPullRequestIDs = missingPullRequestIDs
  }

  enum CodingKeys: String, CodingKey {
    case fetchedAt
    case items
    case missingPullRequestIDs = "missingPullRequestIds"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    fetchedAt = try container.decode(String.self, forKey: .fetchedAt)
    items = normalizedDependencyUpdateItems(
      try container.decode([DependencyUpdateItem].self, forKey: .items)
    )
    missingPullRequestIDs =
      try container.decodeIfPresent([String].self, forKey: .missingPullRequestIDs) ?? []
  }
}

public struct DependencyUpdatesBodyRequest: Codable, Equatable, Sendable {
  public let pullRequestID: String
  public let forceRefresh: Bool
  public let cacheMaxAgeSeconds: UInt64

  public init(
    pullRequestID: String,
    forceRefresh: Bool = false,
    cacheMaxAgeSeconds: UInt64 = 600
  ) {
    self.pullRequestID = pullRequestID
    self.forceRefresh = forceRefresh
    self.cacheMaxAgeSeconds = cacheMaxAgeSeconds
  }

  enum CodingKeys: String, CodingKey {
    case pullRequestID = "pullRequestId"
    case forceRefresh
    case cacheMaxAgeSeconds
  }
}

public struct DependencyUpdatesBodyResponse: Codable, Equatable, Sendable {
  public let pullRequestID: String
  public let body: String
  public let prUpdatedAt: String
  public let fetchedAt: String
  public let fromCache: Bool

  public init(
    pullRequestID: String,
    body: String,
    prUpdatedAt: String,
    fetchedAt: String,
    fromCache: Bool
  ) {
    self.pullRequestID = pullRequestID
    self.body = body
    self.prUpdatedAt = prUpdatedAt
    self.fetchedAt = fetchedAt
    self.fromCache = fromCache
  }

  enum CodingKeys: String, CodingKey {
    case pullRequestID = "pullRequestId"
    case body
    case prUpdatedAt
    case fetchedAt
    case fromCache
  }
}

public struct DependencyUpdatesBodyUpdateRequest: Codable, Equatable, Sendable {
  public let pullRequestID: String
  public let expectedPriorBodySHA256: String
  public let newBody: String

  public init(pullRequestID: String, expectedPriorBodySHA256: String, newBody: String) {
    self.pullRequestID = pullRequestID
    self.expectedPriorBodySHA256 = expectedPriorBodySHA256
    self.newBody = newBody
  }

  enum CodingKeys: String, CodingKey {
    case pullRequestID = "pullRequestId"
    case expectedPriorBodySHA256 = "expectedPriorBodySha256"
    case newBody
  }
}

public enum DependencyUpdatesBodyUpdateOutcome: TaskBoardOpenEnum, CaseIterable, Identifiable {
  case updated
  case bodyDrifted
  case unknown(String)

  public static let allCases: [Self] = [.updated, .bodyDrifted]
  public var id: String { rawValue }

  public var rawValue: String {
    switch self {
    case .updated: "updated"
    case .bodyDrifted: "body_drifted"
    case .unknown(let raw): raw
    }
  }

  public init(rawValue: String) {
    switch rawValue {
    case "updated": self = .updated
    case "body_drifted": self = .bodyDrifted
    default: self = .unknown(rawValue)
    }
  }
}

public struct DependencyUpdatesBodyUpdateResponse: Codable, Equatable, Sendable {
  public let pullRequestID: String
  public let outcome: DependencyUpdatesBodyUpdateOutcome
  public let currentBody: String
  public let currentBodySHA256: String
  public let prUpdatedAt: String
  public let fetchedAt: String

  public init(
    pullRequestID: String,
    outcome: DependencyUpdatesBodyUpdateOutcome,
    currentBody: String,
    currentBodySHA256: String,
    prUpdatedAt: String,
    fetchedAt: String
  ) {
    self.pullRequestID = pullRequestID
    self.outcome = outcome
    self.currentBody = currentBody
    self.currentBodySHA256 = currentBodySHA256
    self.prUpdatedAt = prUpdatedAt
    self.fetchedAt = fetchedAt
  }

  enum CodingKeys: String, CodingKey {
    case pullRequestID = "pullRequestId"
    case outcome
    case currentBody
    case currentBodySHA256 = "currentBodySha256"
    case prUpdatedAt
    case fetchedAt
  }
}
