// Request/response structs for the Files endpoints. Split out of
// `ReviewFile.swift` so the type-models file stays under the
// 420-line cap from CLAUDE.md.

import Foundation

/// Request to list a PR's changed files via the daemon.
public struct ReviewsFilesListRequest: Codable, Equatable, Sendable {
  public let pullRequestID: String
  public let forceRefresh: Bool

  public init(pullRequestID: String, forceRefresh: Bool = false) {
    self.pullRequestID = pullRequestID
    self.forceRefresh = forceRefresh
  }

  enum CodingKeys: String, CodingKey {
    case pullRequestID = "pullRequestId"
    case forceRefresh
  }
}

/// Response shape for the files_list endpoint.
///
/// `paginationComplete` is `true` when the daemon drained every page of
/// the underlying GraphQL `pullRequest.files(...)` connection. `false`
/// indicates the loop bailed under the page cap while GitHub still had
/// `hasNextPage == true` - the response is partial and the UI should
/// surface a "and N more files not loaded" affordance. Older daemons
/// that don't emit the field default to `true` for backwards
/// compatibility.
public struct ReviewsFilesListResponse: Codable, Equatable, Sendable {
  public let pullRequestID: String
  public let number: UInt64?
  public let headRefOid: String
  /// PR's source branch name (`refs/heads/<x>` qualifier dropped).
  /// Optional for back-compat with older daemons that don't emit it.
  public let headRefName: String?
  /// Merge-base OID for the PR. Required for the local-clone diff path
  /// to compute `base..head` patches; missing on older daemons.
  public let baseRefOid: String?
  public let baseRefName: String?
  /// `owner/name` of the repository the PR lives in.
  public let repositoryFullName: String?
  public let viewerCanMarkViewed: Bool
  public let files: [ReviewFile]
  public let fetchedAt: String
  public let paginationComplete: Bool
  public let rateLimitSnapshot: ReviewsRateLimitSnapshot?

  public init(
    pullRequestID: String,
    number: UInt64? = nil,
    headRefOid: String,
    headRefName: String? = nil,
    baseRefOid: String? = nil,
    baseRefName: String? = nil,
    repositoryFullName: String? = nil,
    viewerCanMarkViewed: Bool,
    files: [ReviewFile],
    fetchedAt: String,
    paginationComplete: Bool = true,
    rateLimitSnapshot: ReviewsRateLimitSnapshot? = nil
  ) {
    self.pullRequestID = pullRequestID
    self.number = number
    self.headRefOid = headRefOid
    self.headRefName = headRefName
    self.baseRefOid = baseRefOid
    self.baseRefName = baseRefName
    self.repositoryFullName = repositoryFullName
    self.viewerCanMarkViewed = viewerCanMarkViewed
    self.files = files
    self.fetchedAt = fetchedAt
    self.paginationComplete = paginationComplete
    self.rateLimitSnapshot = rateLimitSnapshot
  }

  enum CodingKeys: String, CodingKey {
    case pullRequestID = "pullRequestId"
    case number
    case headRefOid
    case headRefName
    case baseRefOid
    case baseRefName
    case repositoryFullName
    case viewerCanMarkViewed
    case files
    case fetchedAt
    case paginationComplete
    case rateLimitSnapshot
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    pullRequestID = try container.decode(String.self, forKey: .pullRequestID)
    number = try container.decodeIfPresent(UInt64.self, forKey: .number)
    headRefOid = try container.decode(String.self, forKey: .headRefOid)
    headRefName = try container.decodeIfPresent(String.self, forKey: .headRefName)
    baseRefOid = try container.decodeIfPresent(String.self, forKey: .baseRefOid)
    baseRefName = try container.decodeIfPresent(String.self, forKey: .baseRefName)
    repositoryFullName = try container.decodeIfPresent(String.self, forKey: .repositoryFullName)
    viewerCanMarkViewed = try container.decode(Bool.self, forKey: .viewerCanMarkViewed)
    files = try container.decode([ReviewFile].self, forKey: .files)
    fetchedAt = try container.decode(String.self, forKey: .fetchedAt)
    paginationComplete =
      try container.decodeIfPresent(Bool.self, forKey: .paginationComplete) ?? true
    rateLimitSnapshot = try container.decodeIfPresent(
      ReviewsRateLimitSnapshot.self, forKey: .rateLimitSnapshot)
  }
}

/// Patch fetch request. The Monitor sends its expected head_ref_oid so the
/// daemon can detect force-push drift.
public struct ReviewsFilesPatchRequest: Codable, Equatable, Sendable {
  public let pullRequestID: String
  public let headRefOidExpected: String
  public let paths: [String]
  /// Pull request number. Enables the daemon to fetch GitHub's synthetic
  /// `refs/pull/<number>/head` ref, which works for forks and same-repo PRs.
  public let number: UInt64?
  /// `owner/name` of the repository. Enables the daemon's local-clone
  /// dispatch path. Optional only for back-compat with older callers.
  public let repositoryFullName: String?
  /// Merge-base OID against which to compute the diff.
  public let baseRefOidExpected: String?
  /// PR's source branch name. Lets the local-clone path fetch the
  /// actual PR ref instead of falling back to `refs/heads/main`.
  public let headRefName: String?
  /// PR base branch name. Lets the daemon fetch the base ref before diffing.
  public let baseRefName: String?
  /// User's `filesLargeDiffStrategy` choice from Settings. Daemon honors
  /// `.forceGitHubRest` by skipping the local-clone runtime entirely;
  /// `.autoLocalClone` keeps the default behavior.
  public let largeDiffStrategy: FilesLargeDiffStrategy?

  public init(
    pullRequestID: String,
    headRefOidExpected: String,
    paths: [String],
    number: UInt64? = nil,
    repositoryFullName: String? = nil,
    baseRefOidExpected: String? = nil,
    headRefName: String? = nil,
    baseRefName: String? = nil,
    largeDiffStrategy: FilesLargeDiffStrategy? = nil
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
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    pullRequestID = try container.decode(String.self, forKey: .pullRequestID)
    headRefOidExpected = try container.decode(String.self, forKey: .headRefOidExpected)
    paths = try container.decode([String].self, forKey: .paths)
    number = try container.decodeIfPresent(UInt64.self, forKey: .number)
    repositoryFullName = try container.decodeIfPresent(String.self, forKey: .repositoryFullName)
    baseRefOidExpected = try container.decodeIfPresent(String.self, forKey: .baseRefOidExpected)
    headRefName = try container.decodeIfPresent(String.self, forKey: .headRefName)
    baseRefName = try container.decodeIfPresent(String.self, forKey: .baseRefName)
    largeDiffStrategy = try container.decodeIfPresent(
      FilesLargeDiffStrategy.self, forKey: .largeDiffStrategy)
  }
}

/// One file's patch body plus metadata.
public struct ReviewFilePatch: Codable, Equatable, Sendable, Identifiable {
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
    headRefOid: String = ""
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
  }
}

/// Response carrying patches + drift flag.
public struct ReviewsFilesPatchResponse: Codable, Equatable, Sendable {
  public let pullRequestID: String
  public let patches: [ReviewFilePatch]
  public let drifted: Bool
  public let currentHeadRefOid: String
  public let fetchedAt: String
  public let rateLimitSnapshot: ReviewsRateLimitSnapshot?

  public init(
    pullRequestID: String,
    patches: [ReviewFilePatch],
    drifted: Bool,
    currentHeadRefOid: String,
    fetchedAt: String,
    rateLimitSnapshot: ReviewsRateLimitSnapshot? = nil
  ) {
    self.pullRequestID = pullRequestID
    self.patches = patches
    self.drifted = drifted
    self.currentHeadRefOid = currentHeadRefOid
    self.fetchedAt = fetchedAt
    self.rateLimitSnapshot = rateLimitSnapshot
  }

  enum CodingKeys: String, CodingKey {
    case pullRequestID = "pullRequestId"
    case patches
    case drifted
    case currentHeadRefOid
    case fetchedAt
    case rateLimitSnapshot
  }
}

/// Per-path target for the mark-viewed mutation.
public struct ReviewFilesViewedTarget: Codable, Equatable, Sendable {
  public let path: String
  public let expectedPriorState: ReviewFileViewedState
  public let markViewed: Bool

  public init(
    path: String,
    expectedPriorState: ReviewFileViewedState,
    markViewed: Bool
  ) {
    self.path = path
    self.expectedPriorState = expectedPriorState
    self.markViewed = markViewed
  }
}

/// Batched mark-viewed request.
public struct ReviewsFilesViewedRequest: Codable, Equatable, Sendable {
  public let pullRequestID: String
  public let paths: [ReviewFilesViewedTarget]

  public init(pullRequestID: String, paths: [ReviewFilesViewedTarget]) {
    self.pullRequestID = pullRequestID
    self.paths = paths
  }

  enum CodingKeys: String, CodingKey {
    case pullRequestID = "pullRequestId"
    case paths
  }
}

/// One result row inside the viewed response.
public struct ReviewFilesViewedResult: Codable, Equatable, Sendable {
  public let path: String
  public let outcome: ReviewFileViewedOutcome
  public let viewerViewedState: ReviewFileViewedState

  public init(
    path: String,
    outcome: ReviewFileViewedOutcome,
    viewerViewedState: ReviewFileViewedState
  ) {
    self.path = path
    self.outcome = outcome
    self.viewerViewedState = viewerViewedState
  }
}

/// Response to a mark-viewed batch.
public struct ReviewsFilesViewedResponse: Codable, Equatable, Sendable {
  public let pullRequestID: String
  public let results: [ReviewFilesViewedResult]
  public let fetchedAt: String

  public init(
    pullRequestID: String,
    results: [ReviewFilesViewedResult],
    fetchedAt: String
  ) {
    self.pullRequestID = pullRequestID
    self.results = results
    self.fetchedAt = fetchedAt
  }

  enum CodingKeys: String, CodingKey {
    case pullRequestID = "pullRequestId"
    case results
    case fetchedAt
  }
}

/// Image blob request.
public struct ReviewsFilesBlobRequest: Codable, Equatable, Sendable {
  public let repositoryID: String
  public let oid: String
  public let path: String

  public init(repositoryID: String, oid: String, path: String) {
    self.repositoryID = repositoryID
    self.oid = oid
    self.path = path
  }

  enum CodingKeys: String, CodingKey {
    case repositoryID = "repositoryId"
    case oid
    case path
  }
}

/// Image blob response.
public struct ReviewsFilesBlobResponse: Codable, Equatable, Sendable {
  public let path: String
  public let oid: String
  public let mime: HarnessReviewImageMime
  public let contentBase64: String
  public let byteSize: UInt64
  public let isTruncated: Bool
  public let isTooLarge: Bool
  public let fetchedAt: String
  public let rateLimitSnapshot: ReviewsRateLimitSnapshot?

  public init(
    path: String,
    oid: String,
    mime: HarnessReviewImageMime,
    contentBase64: String,
    byteSize: UInt64,
    isTruncated: Bool = false,
    isTooLarge: Bool = false,
    fetchedAt: String,
    rateLimitSnapshot: ReviewsRateLimitSnapshot? = nil
  ) {
    self.path = path
    self.oid = oid
    self.mime = mime
    self.contentBase64 = contentBase64
    self.byteSize = byteSize
    self.isTruncated = isTruncated
    self.isTooLarge = isTooLarge
    self.fetchedAt = fetchedAt
    self.rateLimitSnapshot = rateLimitSnapshot
  }
}
