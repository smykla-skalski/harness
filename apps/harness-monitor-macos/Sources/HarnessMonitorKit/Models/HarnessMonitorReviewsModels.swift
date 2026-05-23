import Foundation

public struct ReviewsQueryRequest: Codable, Equatable, Sendable {
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

  public init(targets: [ReviewTarget]) {
    self.targets = targets
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

public struct ReviewsSummary: Codable, Equatable, Sendable {
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

  public init(items: [ReviewItem]) {
    total = items.count
    reviewRequired = items.count { $0.reviewStatus == .reviewRequired }
    readyToMerge = items.count { $0.isAutoMergeable }
    autoApprovable = items.count { $0.isAutoApprovable }
    waitingOnChecks = items.count { $0.checkStatus == .pending }
    blocked = items.count { $0.requiresAttention }
  }
}

public struct ReviewItem: Codable, Equatable, Identifiable, Sendable {
  public let pullRequestID: String
  public let repositoryID: String
  public let repository: String
  public let number: UInt64
  public let title: String
  public let url: String
  public let authorLogin: String
  public let state: ReviewPullRequestState
  public let mergeable: ReviewMergeableState
  public let reviewStatus: ReviewReviewStatus
  public let checkStatus: ReviewCheckStatus
  public let policyBlocked: Bool
  public let isDraft: Bool
  public let headSha: String
  public let labels: [String]
  public let checks: [ReviewCheck]
  public let reviews: [PullRequestReview]
  public let additions: UInt64
  public let deletions: UInt64
  public let createdAt: String
  public let updatedAt: String
  public let requiredFailedCheckNames: [String]
  public let viewerCanUpdate: Bool
  public let viewerCanMergeAsAdmin: Bool

  public var id: String { pullRequestID }

  public init(
    pullRequestID: String,
    repositoryID: String,
    repository: String,
    number: UInt64,
    title: String,
    url: String,
    authorLogin: String,
    state: ReviewPullRequestState,
    mergeable: ReviewMergeableState,
    reviewStatus: ReviewReviewStatus,
    checkStatus: ReviewCheckStatus,
    policyBlocked: Bool,
    isDraft: Bool,
    headSha: String,
    labels: [String] = [],
    checks: [ReviewCheck] = [],
    reviews: [PullRequestReview] = [],
    additions: UInt64,
    deletions: UInt64,
    createdAt: String,
    updatedAt: String,
    requiredFailedCheckNames: [String] = [],
    viewerCanUpdate: Bool = true,
    viewerCanMergeAsAdmin: Bool = false
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
    self.requiredFailedCheckNames = requiredFailedCheckNames
    self.viewerCanUpdate = viewerCanUpdate
    self.viewerCanMergeAsAdmin = viewerCanMergeAsAdmin
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
    case requiredFailedCheckNames
    case viewerCanUpdate
    case viewerCanMergeAsAdmin
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    pullRequestID = try container.decode(String.self, forKey: .pullRequestID)
    repositoryID = try container.decode(String.self, forKey: .repositoryID)
    repository = try container.decode(String.self, forKey: .repository)
    number = try container.decode(UInt64.self, forKey: .number)
    title = try container.decode(String.self, forKey: .title)
    url = try container.decode(String.self, forKey: .url)
    authorLogin = try container.decode(String.self, forKey: .authorLogin)
    state = try container.decode(ReviewPullRequestState.self, forKey: .state)
    mergeable = try container.decode(ReviewMergeableState.self, forKey: .mergeable)
    reviewStatus = try container.decode(ReviewReviewStatus.self, forKey: .reviewStatus)
    checkStatus = try container.decode(ReviewCheckStatus.self, forKey: .checkStatus)
    policyBlocked = try container.decode(Bool.self, forKey: .policyBlocked)
    isDraft = try container.decode(Bool.self, forKey: .isDraft)
    headSha = try container.decode(String.self, forKey: .headSha)
    labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
    checks =
      try container.decodeIfPresent([ReviewCheck].self, forKey: .checks) ?? []
    reviews =
      try container.decodeIfPresent([PullRequestReview].self, forKey: .reviews) ?? []
    additions = try container.decode(UInt64.self, forKey: .additions)
    deletions = try container.decode(UInt64.self, forKey: .deletions)
    createdAt = try container.decode(String.self, forKey: .createdAt)
    updatedAt = try container.decode(String.self, forKey: .updatedAt)
    requiredFailedCheckNames =
      try container.decodeIfPresent([String].self, forKey: .requiredFailedCheckNames) ?? []
    // 2026-05-23: default flipped from `true` to `false`. A daemon that
    // does not populate this field for any reason (encoding bug, partial
    // payload, fixture omission) should land action controls as disabled
    // rather than enabled. The version-skew shim in
    // `HarnessMonitorReviewsDaemonNormalizer` re-enables the field when
    // the connected daemon predates the wire schema that added it.
    viewerCanUpdate = try container.decodeIfPresent(Bool.self, forKey: .viewerCanUpdate) ?? false
    viewerCanMergeAsAdmin =
      try container.decodeIfPresent(Bool.self, forKey: .viewerCanMergeAsAdmin) ?? false
  }
}
