import Foundation
import SwiftData

/// Summary row for the cached PR-files metadata fetched by the daemon. One
/// row per pull request id; updating on a new `headRefOid` overwrites the
/// existing row and the per-file detail rows get rewritten in
/// `DependencyUpdateFilesCache`. The summary captures aggregate counts so
/// header widgets can render without iterating all per-file rows.
@Model
public final class CachedDependencyUpdateFilesSummary {
  #Unique<CachedDependencyUpdateFilesSummary>([\.pullRequestID])
  #Index<CachedDependencyUpdateFilesSummary>(
    [\.pullRequestID],
    [\.pullRequestID, \.headRefOid],
    [\.fetchedAt]
  )

  public var pullRequestID: String
  public var headRefOid: String
  public var fetchedAt: Date
  public var totalAdditions: Int
  public var totalDeletions: Int
  public var fileCount: Int
  public var paginationComplete: Bool

  public init(
    pullRequestID: String,
    headRefOid: String,
    fetchedAt: Date = .now,
    totalAdditions: Int = 0,
    totalDeletions: Int = 0,
    fileCount: Int = 0,
    paginationComplete: Bool = true
  ) {
    self.pullRequestID = pullRequestID
    self.headRefOid = headRefOid
    self.fetchedAt = fetchedAt
    self.totalAdditions = totalAdditions
    self.totalDeletions = totalDeletions
    self.fileCount = fileCount
    self.paginationComplete = paginationComplete
  }
}
