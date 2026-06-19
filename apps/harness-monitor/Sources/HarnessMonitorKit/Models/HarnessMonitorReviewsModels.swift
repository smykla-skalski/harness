import Foundation

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
  public let baseRefName: String?
  public let defaultBranchName: String?
  public let backportSource: ReviewBackportSource?
  public let authorLogin: String
  public let authorAvatarURL: URL?
  public let authorAssociation: ReviewAuthorAssociation
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
  public let viewerIsRequestedReviewer: Bool
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
    baseRefName: String? = nil,
    defaultBranchName: String? = nil,
    backportSource: ReviewBackportSource? = nil,
    authorLogin: String,
    authorAvatarURL: URL? = nil,
    authorAssociation: ReviewAuthorAssociation = .none,
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
    viewerIsRequestedReviewer: Bool = false,
    viewerCanUpdate: Bool = true,
    viewerCanMergeAsAdmin: Bool = false
  ) {
    self.pullRequestID = pullRequestID
    self.repositoryID = repositoryID
    self.repository = repository
    self.number = number
    self.title = title
    self.url = url
    self.baseRefName = baseRefName
    self.defaultBranchName = defaultBranchName
    self.backportSource = backportSource
    self.authorLogin = authorLogin
    self.authorAvatarURL = authorAvatarURL
    self.authorAssociation = authorAssociation
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
    self.viewerIsRequestedReviewer = viewerIsRequestedReviewer
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
    case baseRefName
    case defaultBranchName
    case backportSource
    case authorLogin
    case authorAvatarURL = "authorAvatarUrl"
    case authorAssociation
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
    case viewerIsRequestedReviewer
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
    baseRefName = try container.decodeIfPresent(String.self, forKey: .baseRefName)
    defaultBranchName = try container.decodeIfPresent(String.self, forKey: .defaultBranchName)
    backportSource =
      try container.decodeIfPresent(ReviewBackportSource.self, forKey: .backportSource)
    authorLogin = try container.decode(String.self, forKey: .authorLogin)
    authorAvatarURL =
      try container.decodeIfPresent(String.self, forKey: .authorAvatarURL)
      .flatMap(URL.init(string:))
    authorAssociation =
      try container.decodeIfPresent(ReviewAuthorAssociation.self, forKey: .authorAssociation)
      ?? .none
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
    viewerIsRequestedReviewer =
      try container.decodeIfPresent(Bool.self, forKey: .viewerIsRequestedReviewer) ?? false
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

extension ReviewItem {
  public var nonDefaultTargetBranchName: String? {
    guard
      let baseRefName = Self.normalizedBranchName(baseRefName),
      let defaultBranchName = Self.normalizedBranchName(defaultBranchName),
      baseRefName != defaultBranchName
    else {
      return nil
    }
    return baseRefName
  }

  private static func normalizedBranchName(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }
}
