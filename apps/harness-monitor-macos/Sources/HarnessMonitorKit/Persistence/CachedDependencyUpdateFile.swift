import Foundation
import SwiftData

/// Per-file metadata row for the cached PR-files response. The compound key
/// embeds `pullRequestID + headRefOid + path` so a force-push that flips the
/// head OID writes a fresh row set without colliding with the prior state.
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
