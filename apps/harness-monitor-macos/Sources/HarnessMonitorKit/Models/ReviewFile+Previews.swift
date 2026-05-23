import Foundation

/// Bounded preview request for the first lines of selected file patches.
public struct ReviewsFilesPreviewRequest: Codable, Equatable, Sendable {
  public let pullRequestID: String
  public let headRefOidExpected: String
  public let paths: [String]
  public let number: UInt64?
  public let repositoryFullName: String?
  public let baseRefOidExpected: String?
  public let headRefName: String?
  public let baseRefName: String?
  public let largeDiffStrategy: FilesLargeDiffStrategy?
  public let lineLimit: UInt32

  public init(
    pullRequestID: String,
    headRefOidExpected: String,
    paths: [String],
    number: UInt64? = nil,
    repositoryFullName: String? = nil,
    baseRefOidExpected: String? = nil,
    headRefName: String? = nil,
    baseRefName: String? = nil,
    largeDiffStrategy: FilesLargeDiffStrategy? = nil,
    lineLimit: UInt32 = ReviewFilePreview.defaultLineLimit
  ) {
    self.pullRequestID = pullRequestID
    self.headRefOidExpected = headRefOidExpected
    self.paths = paths
    self.number = number
    self.repositoryFullName = repositoryFullName
    self.baseRefOidExpected = baseRefOidExpected
    self.headRefName = headRefName
    self.baseRefName = baseRefName
    self.largeDiffStrategy = largeDiffStrategy
    self.lineLimit = lineLimit
  }

  enum CodingKeys: String, CodingKey {
    case pullRequestID = "pullRequestId"
    case headRefOidExpected
    case paths
    case number
    case repositoryFullName
    case baseRefOidExpected
    case headRefName
    case baseRefName
    case largeDiffStrategy
    case lineLimit
  }
}

/// First-line patch body used by the file-card expansion hot path.
public struct ReviewFilePreview: Codable, Equatable, Sendable, Identifiable {
  public static let defaultLineLimit: UInt32 = 200

  public let path: String
  public let patch: String
  public let status: ReviewFileChangeType
  public let additions: UInt32
  public let deletions: UInt32
  public let truncated: Bool
  public let etag: String?
  public let servedBy: ReviewFileServedBy
  public let fetchedAt: String
  public let headRefOid: String
  public let lineCount: UInt32
  public let lineLimit: UInt32
  public let hasMore: Bool

  public var id: String { path }

  public init(
    path: String,
    patch: String,
    status: ReviewFileChangeType = .modified,
    additions: UInt32 = 0,
    deletions: UInt32 = 0,
    truncated: Bool = false,
    etag: String? = nil,
    servedBy: ReviewFileServedBy = .githubRest,
    fetchedAt: String = "",
    headRefOid: String = "",
    lineCount: UInt32 = 0,
    lineLimit: UInt32 = Self.defaultLineLimit,
    hasMore: Bool = false
  ) {
    self.path = path
    self.patch = patch
    self.status = status
    self.additions = additions
    self.deletions = deletions
    self.truncated = truncated
    self.etag = etag
    self.servedBy = servedBy
    self.fetchedAt = fetchedAt
    self.headRefOid = headRefOid
    self.lineCount = lineCount
    self.lineLimit = lineLimit
    self.hasMore = hasMore
  }
}

/// Response carrying bounded previews plus drift detection.
public struct ReviewsFilesPreviewResponse: Codable, Equatable, Sendable {
  public let pullRequestID: String
  public let previews: [ReviewFilePreview]
  public let drifted: Bool
  public let currentHeadRefOid: String
  public let fetchedAt: String
  public let rateLimitSnapshot: ReviewsRateLimitSnapshot?

  public init(
    pullRequestID: String,
    previews: [ReviewFilePreview],
    drifted: Bool,
    currentHeadRefOid: String,
    fetchedAt: String,
    rateLimitSnapshot: ReviewsRateLimitSnapshot? = nil
  ) {
    self.pullRequestID = pullRequestID
    self.previews = previews
    self.drifted = drifted
    self.currentHeadRefOid = currentHeadRefOid
    self.fetchedAt = fetchedAt
    self.rateLimitSnapshot = rateLimitSnapshot
  }

  enum CodingKeys: String, CodingKey {
    case pullRequestID = "pullRequestId"
    case previews
    case drifted
    case currentHeadRefOid
    case fetchedAt
    case rateLimitSnapshot
  }
}
