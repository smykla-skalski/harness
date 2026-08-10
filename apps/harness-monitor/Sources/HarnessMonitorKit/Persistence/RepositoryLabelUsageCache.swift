import Foundation
import SwiftData

@MainActor
public struct RepositoryLabelUsageCache {
  private let context: ModelContext

  public init(context: ModelContext) {
    self.context = context
  }

  /// Return label names sorted by total usage across `repositories`, then by
  /// most-recent `lastUsedAt`, capped at `limit`. Multi-repo selections sum
  /// counts so a shared label wins over a label that's hot in just one repo.
  public func topUsed(repositories: [String], limit: Int) -> [String] {
    guard limit > 0, !repositories.isEmpty else { return [] }
    let repoSet = Set(repositories)
    let descriptor = FetchDescriptor<CachedReviewLabelUsage>()
    guard let rows = try? context.fetch(descriptor) else { return [] }
    var aggregated: [String: (count: Int, lastUsedAt: Date)] = [:]
    for row in rows where repoSet.contains(row.repository) {
      let current = aggregated[row.label] ?? (0, .distantPast)
      aggregated[row.label] = (
        current.count + row.usageCount,
        max(current.lastUsedAt, row.lastUsedAt)
      )
    }

    return
      aggregated
      .sorted { lhs, rhs in
        if lhs.value.count != rhs.value.count {
          return lhs.value.count > rhs.value.count
        }
        if lhs.value.lastUsedAt != rhs.value.lastUsedAt {
          return lhs.value.lastUsedAt > rhs.value.lastUsedAt
        }
        return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
      }
      .prefix(limit)
      .map(\.key)
  }
}
