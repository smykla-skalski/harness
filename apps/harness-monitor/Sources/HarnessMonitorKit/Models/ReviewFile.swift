// SwiftUI/Foundation DTOs mirroring the daemon's
// src/reviews/files/ surface. Names and JSON keys round-trip
// without translation so a Codable encode of these structs feeds the daemon
// directly.

import Foundation

/// Snake-case-encoded enum mirroring HarnessCodeLanguage in the daemon.
public enum HarnessReviewFileLanguage: String, Codable, Equatable, Sendable, CaseIterable {
  case diff
  case generic
  case json
  case markdown
  case rust
  case shell
  case swift
  case yaml
}

/// Image MIME types the Files section previews inline.
public enum HarnessReviewImageMime: String, Codable, Equatable, Sendable {
  case png
  case jpeg
  case gif
  case svg

  public var ianaString: String {
    switch self {
    case .png: return "image/png"
    case .jpeg: return "image/jpeg"
    case .gif: return "image/gif"
    case .svg: return "image/svg+xml"
    }
  }
}

/// Change-type enum mirroring the daemon's GraphQL ingest. `other` is the
/// forward-compat slot for unknown values.
public enum ReviewFileChangeType: String, Codable, Equatable, Sendable, CaseIterable {
  case added
  case copied
  case deleted
  case modified
  case renamed
  case changed
  case other
}

/// Viewed-state enum mirroring GitHub's `FileViewedState`. `unviewed` is the
/// default.
public enum ReviewFileViewedState: String, Codable, Equatable, Sendable, CaseIterable {
  case dismissed
  case viewed
  case unviewed
}

/// Provenance tag on a patch so the UI can label which path served it.
public enum ReviewFileServedBy: String, Codable, Equatable, Sendable, CaseIterable {
  case githubRest = "github_rest"
  case localClone = "local_clone"
  case githubRestFallback = "github_rest_fallback"
}

/// Outcome of a mark-viewed flip. Mirrors the daemon enum.
public enum ReviewFileViewedOutcome: String, Codable, Equatable, Sendable, CaseIterable {
  case updated
  case drifted
  case failed
}

/// Settings choice for substantial-PR strategy. Mirrors the daemon enum.
public enum FilesLargeDiffStrategy: String, Codable, Equatable, Sendable, CaseIterable {
  case autoLocalClone = "auto_local_clone"
  case forceGitHubRest = "force_git_hub_rest"
}

/// Per-file metadata returned by the daemon's `files_list` endpoint.
public struct ReviewFile: Codable, Equatable, Sendable, Identifiable {
  public let path: String
  public let previousPath: String?
  public let changeType: ReviewFileChangeType
  public let additions: UInt32
  public let deletions: UInt32
  public let viewerViewedState: ReviewFileViewedState
  public let isBinary: Bool
  public let languageHint: HarnessReviewFileLanguage
  public let modeChange: String?

  public var id: String { path }

  public init(
    path: String,
    previousPath: String? = nil,
    changeType: ReviewFileChangeType = .modified,
    additions: UInt32 = 0,
    deletions: UInt32 = 0,
    viewerViewedState: ReviewFileViewedState = .unviewed,
    isBinary: Bool = false,
    languageHint: HarnessReviewFileLanguage = .generic,
    modeChange: String? = nil
  ) {
    self.path = path
    self.previousPath = previousPath
    self.changeType = changeType
    self.additions = additions
    self.deletions = deletions
    self.viewerViewedState = viewerViewedState
    self.isBinary = isBinary
    self.languageHint = languageHint
    self.modeChange = modeChange
  }
}

/// Lightweight rate-limit snapshot the daemon attaches to most responses.
public struct ReviewsRateLimitSnapshot: Codable, Equatable, Sendable {
  public let remaining: UInt32
  public let limit: UInt32
  public let resetAt: String?
  public let cost: UInt32?

  public init(remaining: UInt32, limit: UInt32, resetAt: String? = nil, cost: UInt32? = nil) {
    self.remaining = remaining
    self.limit = limit
    self.resetAt = resetAt
    self.cost = cost
  }
}

/// One local clone the daemon is maintaining.
public struct ReviewLocalCloneEntry: Codable, Equatable, Sendable, Identifiable {
  public let repoFullName: String
  public let repoKeySegment: String
  public let sizeBytes: UInt64
  public let createdAt: String
  public let lastUsedAt: String
  public let lastFetchedAt: String

  public var id: String { repoFullName }

  public init(
    repoFullName: String,
    repoKeySegment: String,
    sizeBytes: UInt64,
    createdAt: String,
    lastUsedAt: String,
    lastFetchedAt: String
  ) {
    self.repoFullName = repoFullName
    self.repoKeySegment = repoKeySegment
    self.sizeBytes = sizeBytes
    self.createdAt = createdAt
    self.lastUsedAt = lastUsedAt
    self.lastFetchedAt = lastFetchedAt
  }
}
