import Foundation
import SwiftData

/// Persisted raw avatar bytes keyed by GitHub's exact `avatarUrl`.
/// The UI keeps a small in-memory decoded-thumbnail cache separately;
/// this row prevents repeated daemon/GitHub round-trips across timeline
/// revisits and app relaunches.
@Model
public final class CachedReviewAvatar {
  #Unique<CachedReviewAvatar>([\.avatarURL])
  #Index<CachedReviewAvatar>([\.avatarURL], [\.lastAccessedAt])

  public var avatarURL: String
  public var mimeType: String
  public var contentData: Data
  public var fetchedAt: Date
  public var lastAccessedAt: Date

  public init(
    avatarURL: String,
    mimeType: String,
    contentData: Data,
    fetchedAt: Date = .now,
    lastAccessedAt: Date = .now
  ) {
    self.avatarURL = avatarURL
    self.mimeType = mimeType
    self.contentData = contentData
    self.fetchedAt = fetchedAt
    self.lastAccessedAt = lastAccessedAt
  }
}
