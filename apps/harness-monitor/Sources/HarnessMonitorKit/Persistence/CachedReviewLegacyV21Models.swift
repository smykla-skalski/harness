import Foundation
import SwiftData

/// Historical V21 entity definitions retained so the V21 schema description
/// can still materialize when the Reviews feature rename promotes the schema
/// to V22. SwiftData identifies entities by their `@Model` class name, so the
/// V21→V22 custom migration depends on both the old `CachedDependency*`
/// classes and the renamed `CachedReview*` classes existing side by side at
/// migration time. These types are intentionally minimal — only the fields
/// and init signatures needed to read existing rows during `willMigrate`.
/// They MUST NOT be referenced by any post-V21 schema or store opened with
/// the V22 schema; after the V21→V22 stage runs once the rows are gone and
/// these classes become dead storage definitions kept only for migration
/// support.

@Model
public final class CachedDependencyUpdatesSnapshot {
  #Unique<CachedDependencyUpdatesSnapshot>([\.preferencesHash])
  #Index<CachedDependencyUpdatesSnapshot>([\.cachedAt])

  public var preferencesHash: String
  public var cachedAt: Date
  public var responseData: Data

  public init(
    preferencesHash: String,
    cachedAt: Date = .now,
    responseData: Data = Data()
  ) {
    self.preferencesHash = preferencesHash
    self.cachedAt = cachedAt
    self.responseData = responseData
  }
}

@Model
public final class CachedDependencyRepositoryLabels {
  #Unique<CachedDependencyRepositoryLabels>([\.repository])
  #Index<CachedDependencyRepositoryLabels>([\.repository], [\.cachedAt])

  public var repository: String
  public var cachedAt: Date
  public var labelsData: Data

  public init(
    repository: String,
    cachedAt: Date = .now,
    labelsData: Data = Data()
  ) {
    self.repository = repository
    self.cachedAt = cachedAt
    self.labelsData = labelsData
  }
}

@Model
public final class CachedDependencyLabelUsage {
  #Unique<CachedDependencyLabelUsage>([\.compoundKey])
  #Index<CachedDependencyLabelUsage>(
    [\.compoundKey],
    [\.repository],
    [\.repository, \.usageCount],
    [\.repository, \.lastUsedAt]
  )

  public var compoundKey: String
  public var repository: String
  public var label: String
  public var usageCount: Int
  public var lastUsedAt: Date

  public init(
    repository: String,
    label: String,
    usageCount: Int = 1,
    lastUsedAt: Date = .now
  ) {
    self.compoundKey = Self.makeCompoundKey(repository: repository, label: label)
    self.repository = repository
    self.label = label
    self.usageCount = usageCount
    self.lastUsedAt = lastUsedAt
  }

  static func makeCompoundKey(repository: String, label: String) -> String {
    "\(repository)\u{1F}\(label)"
  }
}

@Model
public final class CachedDependencyUpdatesRepoSyncState {
  #Unique<CachedDependencyUpdatesRepoSyncState>([\.compoundKey])
  #Index<CachedDependencyUpdatesRepoSyncState>(
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

@Model
public final class CachedDependencyUpdateFile {
  #Unique<CachedDependencyUpdateFile>([\.compoundKey])
  #Index<CachedDependencyUpdateFile>(
    [\.compoundKey],
    [\.pullRequestID, \.headRefOid],
    [\.path]
  )

  public var compoundKey: String
  public var pullRequestID: String
  public var headRefOid: String
  public var path: String
  public var previousPath: String?
  public var changeTypeRaw: String
  public var additions: Int
  public var deletions: Int
  public var isBinary: Bool
  public var languageHintRaw: String?
  public var modeChange: String?
  public var sortIndex: Int

  public init(
    pullRequestID: String,
    headRefOid: String,
    path: String,
    previousPath: String? = nil,
    changeTypeRaw: String,
    additions: Int = 0,
    deletions: Int = 0,
    isBinary: Bool = false,
    languageHintRaw: String? = nil,
    modeChange: String? = nil,
    sortIndex: Int = 0
  ) {
    self.compoundKey = Self.makeCompoundKey(
      pullRequestID: pullRequestID,
      headRefOid: headRefOid,
      path: path
    )
    self.pullRequestID = pullRequestID
    self.headRefOid = headRefOid
    self.path = path
    self.previousPath = previousPath
    self.changeTypeRaw = changeTypeRaw
    self.additions = additions
    self.deletions = deletions
    self.isBinary = isBinary
    self.languageHintRaw = languageHintRaw
    self.modeChange = modeChange
    self.sortIndex = sortIndex
  }

  static func makeCompoundKey(
    pullRequestID: String,
    headRefOid: String,
    path: String
  ) -> String {
    "\(pullRequestID)\u{1F}\(headRefOid)\u{1F}\(path)"
  }
}

@Model
public final class CachedDependencyUpdateFileViewedState {
  #Unique<CachedDependencyUpdateFileViewedState>([\.compoundKey])
  #Index<CachedDependencyUpdateFileViewedState>(
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
    CachedDependencyUpdateFile.makeCompoundKey(
      pullRequestID: pullRequestID,
      headRefOid: headRefOid,
      path: path
    )
  }
}
