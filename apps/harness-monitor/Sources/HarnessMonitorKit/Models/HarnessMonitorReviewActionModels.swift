import Foundation

public struct ReviewCheck: Codable, Equatable, Hashable, Identifiable, Sendable {
  public let name: String
  public let status: ReviewCheckRunStatus
  public let conclusion: ReviewCheckConclusion
  public let checkSuiteID: String?
  public let detailsURL: String?

  public var id: String { "\(name)-\(checkSuiteID ?? "none")-\(detailsURL ?? "none")" }

  public init(
    name: String,
    status: ReviewCheckRunStatus,
    conclusion: ReviewCheckConclusion,
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

/// Raw review events can repeat the same author/state combination, so SwiftUI
/// callers must provide positional identity when rendering these rows.
public struct PullRequestReview: Codable, Equatable, Sendable {
  public let author: String
  public let authorAvatarURL: URL?
  public let state: ReviewReviewEventState

  public init(
    author: String,
    authorAvatarURL: URL? = nil,
    state: ReviewReviewEventState
  ) {
    self.author = author
    self.authorAvatarURL = authorAvatarURL
    self.state = state
  }

  enum CodingKeys: String, CodingKey {
    case author
    case authorAvatarURL = "authorAvatarUrl"
    case state
  }
}

public struct ReviewTarget: Codable, Equatable, Sendable {
  public let pullRequestID: String
  public let repositoryID: String
  public let repository: String
  public let number: UInt64
  public let url: String
  public let state: ReviewPullRequestState
  public let isDraft: Bool
  public let headSha: String
  public let mergeable: ReviewMergeableState
  public let reviewStatus: ReviewReviewStatus
  public let checkStatus: ReviewCheckStatus
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
    state: ReviewPullRequestState = .open,
    isDraft: Bool = false,
    headSha: String,
    mergeable: ReviewMergeableState,
    reviewStatus: ReviewReviewStatus,
    checkStatus: ReviewCheckStatus,
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
      try container.decodeIfPresent(ReviewPullRequestState.self, forKey: .state) ?? .open
    isDraft = try container.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
    headSha = try container.decode(String.self, forKey: .headSha)
    mergeable = try container.decode(ReviewMergeableState.self, forKey: .mergeable)
    reviewStatus = try container.decode(ReviewReviewStatus.self, forKey: .reviewStatus)
    checkStatus = try container.decode(ReviewCheckStatus.self, forKey: .checkStatus)
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

public struct ReviewsActionResponse: Codable, Equatable, Sendable {
  public let summary: String
  public let results: [ReviewActionResult]

  public init(summary: String, results: [ReviewActionResult] = []) {
    self.summary = summary
    self.results = results
  }
}

public struct ReviewActionResult: Codable, Equatable, Sendable {
  public let repository: String
  public let number: UInt64
  public let action: ReviewActionKind
  public let outcome: ReviewActionOutcome
  public let message: String?
  public let timelineEntry: ReviewTimelineEntry?

  public init(
    repository: String,
    number: UInt64,
    action: ReviewActionKind,
    outcome: ReviewActionOutcome,
    message: String? = nil,
    timelineEntry: ReviewTimelineEntry? = nil
  ) {
    self.repository = repository
    self.number = number
    self.action = action
    self.outcome = outcome
    self.message = message
    self.timelineEntry = timelineEntry
  }
}

public struct ReviewsCacheClearResponse: Codable, Equatable, Sendable {
  public let clearedEntries: Int

  public init(clearedEntries: Int) {
    self.clearedEntries = clearedEntries
  }
}

public struct ReviewsRefreshRequest: Codable, Equatable, Sendable {
  public let targets: [ReviewTarget]
  public let backportDetectionEnabled: Bool
  public let backportPatterns: [String]

  public init(
    targets: [ReviewTarget],
    backportDetectionEnabled: Bool = true,
    backportPatterns: [String] = ReviewsQueryRequest.defaultBackportPatterns
  ) {
    self.targets = targets
    self.backportDetectionEnabled = backportDetectionEnabled
    self.backportPatterns = backportPatterns
  }
}

public struct ReviewsRefreshResponse: Codable, Equatable, Sendable {
  public let fetchedAt: String
  public let items: [ReviewItem]
  public let missingPullRequestIDs: [String]

  public init(
    fetchedAt: String,
    items: [ReviewItem] = [],
    missingPullRequestIDs: [String] = []
  ) {
    self.fetchedAt = fetchedAt
    self.items = normalizedReviewItems(items)
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
    items = normalizedReviewItems(
      try container.decode([ReviewItem].self, forKey: .items)
    )
    missingPullRequestIDs =
      try container.decodeIfPresent([String].self, forKey: .missingPullRequestIDs) ?? []
  }
}

public struct ReviewsBodyRequest: Codable, Equatable, Sendable {
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

public struct ReviewsBodyResponse: Codable, Equatable, Sendable {
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

public struct ReviewsBodyUpdateRequest: Codable, Equatable, Sendable {
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

public enum ReviewsBodyUpdateOutcome: TaskBoardOpenEnum, CaseIterable, Identifiable {
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

public struct ReviewsBodyUpdateResponse: Codable, Equatable, Sendable {
  public let pullRequestID: String
  public let outcome: ReviewsBodyUpdateOutcome
  public let currentBody: String
  public let currentBodySHA256: String
  public let prUpdatedAt: String
  public let fetchedAt: String

  public init(
    pullRequestID: String,
    outcome: ReviewsBodyUpdateOutcome,
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
