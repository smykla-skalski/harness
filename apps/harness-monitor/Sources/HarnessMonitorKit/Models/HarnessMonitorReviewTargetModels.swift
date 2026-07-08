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
  public let hasConflictMarkers: Bool?
  public let viewerHasActiveApproval: Bool?
  public let autoMergeEnabled: Bool?
  public let approvalsSatisfiedAfterViewerApproval: Bool?

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
    viewerCanUpdate: Bool = true,
    hasConflictMarkers: Bool? = nil,
    viewerHasActiveApproval: Bool? = nil,
    autoMergeEnabled: Bool? = nil,
    approvalsSatisfiedAfterViewerApproval: Bool? = nil
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
    self.hasConflictMarkers = hasConflictMarkers
    self.viewerHasActiveApproval = viewerHasActiveApproval
    self.autoMergeEnabled = autoMergeEnabled
    self.approvalsSatisfiedAfterViewerApproval = approvalsSatisfiedAfterViewerApproval
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
    case hasConflictMarkers
    case viewerHasActiveApproval
    case autoMergeEnabled
    case approvalsSatisfiedAfterViewerApproval = "approvalRequirementSatisfiedAfterViewerApproval"
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
    hasConflictMarkers =
      try container.decodeIfPresent(Bool.self, forKey: .hasConflictMarkers)
    viewerHasActiveApproval =
      try container.decodeIfPresent(Bool.self, forKey: .viewerHasActiveApproval)
    autoMergeEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .autoMergeEnabled)
    approvalsSatisfiedAfterViewerApproval =
      try container.decodeIfPresent(Bool.self, forKey: .approvalsSatisfiedAfterViewerApproval)
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
    try container.encodeIfPresent(hasConflictMarkers, forKey: .hasConflictMarkers)
    try container.encodeIfPresent(viewerHasActiveApproval, forKey: .viewerHasActiveApproval)
    try container.encodeIfPresent(autoMergeEnabled, forKey: .autoMergeEnabled)
    try container.encodeIfPresent(
      approvalsSatisfiedAfterViewerApproval,
      forKey: .approvalsSatisfiedAfterViewerApproval
    )
  }
}
