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

public struct DependencyUpdatesRepositoryCatalogRequest: Codable, Equatable, Sendable {
  public let organization: String

  public init(organization: String) {
    self.organization = organization
  }
}

public struct DependencyUpdatesRepositoryCatalogResponse: Codable, Equatable, Sendable {
  public let organization: String
  public let repositories: [String]

  public init(organization: String, repositories: [String]) {
    self.organization = organization
    self.repositories = repositories
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

public struct DependencyUpdatesCommentRequest: Codable, Equatable, Sendable {
  public let targets: [DependencyUpdateTarget]
  public let body: String

  public init(targets: [DependencyUpdateTarget], body: String) {
    self.targets = targets
    self.body = body
  }
}

public struct DependencyUpdatesQueryResponse: Codable, Equatable, Sendable {
  public let fetchedAt: String
  public let fromCache: Bool
  public let summary: DependencyUpdatesSummary
  public let items: [DependencyUpdateItem]
  public let repositoryLabels: [String: [DependencyUpdateRepositoryLabel]]

  public init(
    fetchedAt: String,
    fromCache: Bool,
    summary: DependencyUpdatesSummary,
    items: [DependencyUpdateItem],
    repositoryLabels: [String: [DependencyUpdateRepositoryLabel]] = [:]
  ) {
    let normalizedItems = normalizedDependencyUpdateItems(items)
    self.fetchedAt = fetchedAt
    self.fromCache = fromCache
    self.summary =
      normalizedItems.count == items.count
      ? summary
      : DependencyUpdatesSummary(items: normalizedItems)
    self.items = normalizedItems
    self.repositoryLabels = repositoryLabels
  }

  enum CodingKeys: String, CodingKey {
    case fetchedAt
    case fromCache
    case summary
    case items
    case repositoryLabels
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedSummary = try container.decode(DependencyUpdatesSummary.self, forKey: .summary)
    let decodedItems = try container.decode([DependencyUpdateItem].self, forKey: .items)
    let normalizedItems = normalizedDependencyUpdateItems(decodedItems)
    fetchedAt = try container.decode(String.self, forKey: .fetchedAt)
    fromCache = try container.decode(Bool.self, forKey: .fromCache)
    summary =
      normalizedItems.count == decodedItems.count
      ? decodedSummary
      : DependencyUpdatesSummary(items: normalizedItems)
    items = normalizedItems
    repositoryLabels =
      try container.decodeIfPresent(
        [String: [DependencyUpdateRepositoryLabel]].self,
        forKey: .repositoryLabels
      ) ?? [:]
  }
}

public struct DependencyUpdateRepositoryLabel: Codable, Equatable, Identifiable, Sendable, Hashable
{
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

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    pullRequestID = try container.decode(String.self, forKey: .pullRequestID)
    repositoryID = try container.decode(String.self, forKey: .repositoryID)
    repository = try container.decode(String.self, forKey: .repository)
    number = try container.decode(UInt64.self, forKey: .number)
    title = try container.decode(String.self, forKey: .title)
    url = try container.decode(String.self, forKey: .url)
    authorLogin = try container.decode(String.self, forKey: .authorLogin)
    state = try container.decode(DependencyUpdatePullRequestState.self, forKey: .state)
    mergeable = try container.decode(DependencyUpdateMergeableState.self, forKey: .mergeable)
    reviewStatus = try container.decode(DependencyUpdateReviewStatus.self, forKey: .reviewStatus)
    checkStatus = try container.decode(DependencyUpdateCheckStatus.self, forKey: .checkStatus)
    policyBlocked = try container.decode(Bool.self, forKey: .policyBlocked)
    isDraft = try container.decode(Bool.self, forKey: .isDraft)
    headSha = try container.decode(String.self, forKey: .headSha)
    labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
    checks =
      try container.decodeIfPresent([DependencyUpdateCheck].self, forKey: .checks) ?? []
    reviews =
      try container.decodeIfPresent([DependencyUpdateReview].self, forKey: .reviews) ?? []
    additions = try container.decode(UInt64.self, forKey: .additions)
    deletions = try container.decode(UInt64.self, forKey: .deletions)
    createdAt = try container.decode(String.self, forKey: .createdAt)
    updatedAt = try container.decode(String.self, forKey: .updatedAt)
  }
}

func normalizedDependencyUpdateItems(
  _ items: [DependencyUpdateItem]
) -> [DependencyUpdateItem] {
  guard items.count > 1 else { return items }
  let formatter = ISO8601DateFormatter()
  var uniqueItems: [DependencyUpdateItem] = []
  uniqueItems.reserveCapacity(items.count)
  var indexByPullRequestID: [String: Int] = [:]

  for item in items {
    if let existingIndex = indexByPullRequestID[item.pullRequestID] {
      let existingItem = uniqueItems[existingIndex]
      if dependencyUpdateItem(item, shouldReplace: existingItem, using: formatter) {
        uniqueItems[existingIndex] = item
      }
      continue
    }

    indexByPullRequestID[item.pullRequestID] = uniqueItems.count
    uniqueItems.append(item)
  }

  return uniqueItems
}

private func dependencyUpdateItem(
  _ candidate: DependencyUpdateItem,
  shouldReplace existing: DependencyUpdateItem,
  using formatter: ISO8601DateFormatter
) -> Bool {
  let candidateDate = formatter.date(from: candidate.updatedAt)
  let existingDate = formatter.date(from: existing.updatedAt)

  switch (candidateDate, existingDate) {
  case (let candidateDate?, let existingDate?) where candidateDate != existingDate:
    return candidateDate > existingDate
  case (_?, nil):
    return true
  case (nil, _?):
    return false
  default:
    return candidate.updatedAt >= existing.updatedAt
  }
}
