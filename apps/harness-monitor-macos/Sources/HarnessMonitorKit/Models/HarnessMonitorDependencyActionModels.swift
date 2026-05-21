import Foundation

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
