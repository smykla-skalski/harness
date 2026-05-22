import Foundation
import SwiftData

/// Persisted `viewerViewedState` for a single (pullRequestID, headRefOid,
/// path) cell. Keeping this in its own table (rather than as a column on
/// `CachedReviewFile`) lets the daemon refresh the file list
/// without overwriting an in-flight mark-viewed mutation.
@Model
public final class CachedReviewFileViewedState {
  #Unique<CachedReviewFileViewedState>([\.compoundKey])
  #Index<CachedReviewFileViewedState>(
    [\.compoundKey],
    [\.pullRequestID, \.headRefOid],
    [\.updatedAt]
  )

  public var compoundKey: String
  public var pullRequestID: String
  public var headRefOid: String
  public var path: String
  public var viewedStateRaw: String
  public var updatedAt: Date

  public init(
    pullRequestID: String,
    headRefOid: String,
    path: String,
    viewedStateRaw: String,
    updatedAt: Date = .now
  ) {
    self.compoundKey = Self.makeCompoundKey(
      pullRequestID: pullRequestID,
      headRefOid: headRefOid,
      path: path
    )
    self.pullRequestID = pullRequestID
    self.headRefOid = headRefOid
    self.path = path
    self.viewedStateRaw = viewedStateRaw
    self.updatedAt = updatedAt
  }

  static func makeCompoundKey(
    pullRequestID: String,
    headRefOid: String,
    path: String
  ) -> String {
    CachedReviewFile.makeCompoundKey(
      pullRequestID: pullRequestID,
      headRefOid: headRefOid,
      path: path
    )
  }
}
