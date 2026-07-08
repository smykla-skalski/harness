import Foundation

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
