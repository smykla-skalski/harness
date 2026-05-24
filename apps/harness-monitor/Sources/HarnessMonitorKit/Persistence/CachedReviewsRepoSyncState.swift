import Foundation
import SwiftData

@Model
public final class CachedReviewsRepoSyncState {
  #Unique<CachedReviewsRepoSyncState>([\.compoundKey])
  #Index<CachedReviewsRepoSyncState>(
    [\.compoundKey],
    [\.preferencesHash],
    [\.preferencesHash, \.lastSyncedAt]
  )

  public var compoundKey: String
  public var preferencesHash: String
  public var repository: String
  public var lastSyncedAt: Date

  public init(
    preferencesHash: String,
    repository: String,
    lastSyncedAt: Date = .now
  ) {
    self.compoundKey = Self.makeCompoundKey(
      preferencesHash: preferencesHash,
      repository: repository
    )
    self.preferencesHash = preferencesHash
    self.repository = repository
    self.lastSyncedAt = lastSyncedAt
  }

  static func makeCompoundKey(preferencesHash: String, repository: String) -> String {
    "\(preferencesHash)\u{1F}\(repository)"
  }
}
