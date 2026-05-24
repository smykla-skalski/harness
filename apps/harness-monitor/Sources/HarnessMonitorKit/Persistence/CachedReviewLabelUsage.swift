import Foundation
import SwiftData

@Model
public final class CachedReviewLabelUsage {
  #Unique<CachedReviewLabelUsage>([\.compoundKey])
  #Index<CachedReviewLabelUsage>(
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
