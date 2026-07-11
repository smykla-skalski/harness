import Foundation

public struct ReviewsQueryRequest: Codable, Equatable, Sendable {
  public static let defaultBackportPatterns: [String] = [
    #"(?i)\s*\(backport\s+of\s+#(?P<number>\d+)\)\s*$"#,
    #"(?i)\s*\[backport\s+of\s+#(?P<number>\d+)\]\s*$"#,
  ]

  public let authors: [String]
  public let organizations: [String]
  public let repositories: [String]
  public let excludeRepositories: [String]
  public let forceRefresh: Bool
  public let cacheMaxAgeSeconds: UInt64
  public let backportDetectionEnabled: Bool
  public let backportPatterns: [String]

  public init(
    authors: [String] = [],
    organizations: [String] = [],
    repositories: [String] = [],
    excludeRepositories: [String] = [],
    forceRefresh: Bool = false,
    cacheMaxAgeSeconds: UInt64 = 600,
    backportDetectionEnabled: Bool = true,
    backportPatterns: [String] = Self.defaultBackportPatterns
  ) {
    self.authors = authors
    self.organizations = organizations
    self.repositories = repositories
    self.excludeRepositories = excludeRepositories
    self.forceRefresh = forceRefresh
    self.cacheMaxAgeSeconds = cacheMaxAgeSeconds
    self.backportDetectionEnabled = backportDetectionEnabled
    self.backportPatterns = backportPatterns
  }
}

public struct ReviewsRepositoryCatalogRequest: Codable, Equatable, Sendable {
  public let organization: String

  public init(organization: String) {
    self.organization = organization
  }
}

public struct ReviewsRepositoryCatalogResponse: Codable, Equatable, Sendable {
  public let organization: String
  public let repositories: [String]

  public init(organization: String, repositories: [String]) {
    self.organization = organization
    self.repositories = repositories
  }
}

public struct ReviewsApproveRequest: Codable, Equatable, Sendable {
  public let targets: [ReviewTarget]
  public let source: ReviewsApproveRequestSource

  public init(targets: [ReviewTarget], source: ReviewsApproveRequestSource) {
    self.targets = targets
    self.source = source
  }
}

public struct ReviewsMergeRequest: Codable, Equatable, Sendable {
  public let targets: [ReviewTarget]
  public let method: TaskBoardGitHubMergeMethod

  public init(
    targets: [ReviewTarget],
    method: TaskBoardGitHubMergeMethod = .squash
  ) {
    self.targets = targets
    self.method = method
  }
}

public struct ReviewsRerunChecksRequest: Codable, Equatable, Sendable {
  public let targets: [ReviewTarget]

  public init(targets: [ReviewTarget]) {
    self.targets = targets
  }
}

public struct ReviewsLabelRequest: Codable, Equatable, Sendable {
  public let targets: [ReviewTarget]
  public let label: String

  public init(targets: [ReviewTarget], label: String) {
    self.targets = targets
    self.label = label
  }
}

public struct ReviewsAutoRequest: Codable, Equatable, Sendable {
  public let targets: [ReviewTarget]
  public let method: TaskBoardGitHubMergeMethod

  public init(
    targets: [ReviewTarget],
    method: TaskBoardGitHubMergeMethod = .squash
  ) {
    self.targets = targets
    self.method = method
  }
}

public struct ReviewsCommentRequest: Codable, Equatable, Sendable {
  public let targets: [ReviewTarget]
  public let body: String

  public init(targets: [ReviewTarget], body: String) {
    self.targets = targets
    self.body = body
  }
}

/// Re-request a fresh review from a specific GitHub login on each target.
/// The daemon delegates to GitHub's `requestedReviewers` endpoint, which
/// drops the reviewer back into the requested-reviewers list so the
/// pending dot returns next time the PR is fetched.
public struct ReviewsRequestReviewRequest: Codable, Equatable, Sendable {
  public let targets: [ReviewTarget]
  public let reviewerLogin: String

  public init(targets: [ReviewTarget], reviewerLogin: String) {
    self.targets = targets
    self.reviewerLogin = reviewerLogin
  }

  enum CodingKeys: String, CodingKey {
    case targets
    case reviewerLogin = "reviewer_login"
  }
}

public struct ReviewsQueryResponse: Codable, Equatable, Sendable {
  public let fetchedAt: String
  public let fromCache: Bool
  public let summary: ReviewsSummary
  public let items: [ReviewItem]
  public let repositoryLabels: [String: [ReviewRepositoryLabel]]
  /// GitHub login of the authenticated viewer that fetched these PRs.
  /// Drives the "(you)" marker on the reviewer pill and the "Commenting
  /// as @viewer" caption in the composer. `nil` when the daemon could
  /// not resolve the viewer (revoked token, transient GraphQL failure).
  public let viewerLogin: String?

  public init(
    fetchedAt: String,
    fromCache: Bool,
    summary: ReviewsSummary,
    items: [ReviewItem],
    repositoryLabels: [String: [ReviewRepositoryLabel]] = [:],
    viewerLogin: String? = nil
  ) {
    let normalizedItems = normalizedReviewItems(items)
    self.fetchedAt = fetchedAt
    self.fromCache = fromCache
    self.summary =
      normalizedItems.count == items.count
      ? summary
      : ReviewsSummary(items: normalizedItems)
    self.items = normalizedItems
    self.repositoryLabels = repositoryLabels
    self.viewerLogin = viewerLogin
  }

  enum CodingKeys: String, CodingKey {
    case fetchedAt
    case fromCache
    case summary
    case items
    case repositoryLabels
    case viewerLogin
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedSummary = try container.decode(ReviewsSummary.self, forKey: .summary)
    let decodedItems = try container.decode([ReviewItem].self, forKey: .items)
    let normalizedItems = normalizedReviewItems(decodedItems)
    fetchedAt = try container.decode(String.self, forKey: .fetchedAt)
    fromCache = try container.decode(Bool.self, forKey: .fromCache)
    summary =
      normalizedItems.count == decodedItems.count
      ? decodedSummary
      : ReviewsSummary(items: normalizedItems)
    items = normalizedItems
    repositoryLabels =
      try container.decodeIfPresent(
        [String: [ReviewRepositoryLabel]].self,
        forKey: .repositoryLabels
      ) ?? [:]
    viewerLogin = try container.decodeIfPresent(String.self, forKey: .viewerLogin)
  }
}

public struct ReviewRepositoryLabel: Codable, Equatable, Identifiable, Sendable, Hashable {
  public let name: String
  public let color: String?
  public let description: String?

  public var id: String { name }

  public init(name: String, color: String? = nil, description: String? = nil) {
    self.name = name
    self.color = color
    self.description = description
  }

  enum CodingKeys: String, CodingKey {
    case name
    case color
    case description
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    color = try container.decodeIfPresent(String.self, forKey: .color)
    description = try container.decodeIfPresent(String.self, forKey: .description)
  }
}
