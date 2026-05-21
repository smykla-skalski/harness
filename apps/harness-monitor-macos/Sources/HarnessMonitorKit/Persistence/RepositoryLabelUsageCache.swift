import Foundation
import SwiftData

@MainActor
public struct RepositoryLabelUsageCache {
  private let context: ModelContext

  public init(context: ModelContext) {
    self.context = context
  }

  /// Record one application of `label` to a pull request in `repository`.
  /// Upserts the (repository, label) row, increments `usageCount`, and bumps
  /// `lastUsedAt` so the picker's "Frequently Used" section reflects current
  /// behavior.
  public func recordUse(repository: String, label: String) {
    guard !repository.isEmpty, !label.isEmpty else { return }
    do {
      let key = CachedDependencyLabelUsage.makeCompoundKey(
        repository: repository,
        label: label
      )
      let descriptor = FetchDescriptor<CachedDependencyLabelUsage>(
        predicate: #Predicate { $0.compoundKey == key }
      )
      let existing = try context.fetch(descriptor).first
      if let existing {
        existing.usageCount += 1
        existing.lastUsedAt = .now
      } else {
        let row = CachedDependencyLabelUsage(repository: repository, label: label)
        context.insert(row)
      }
      try context.save()
    } catch {
      HarnessMonitorLogger.store.warning(
        """
        Failed to record dependency label usage; \
        repository=\(repository, privacy: .public) \
        label=\(label, privacy: .public) \
        error=\(String(reflecting: error), privacy: .public)
        """
      )
    }
  }

  /// Return label names sorted by total usage across `repositories`, then by
  /// most-recent `lastUsedAt`, capped at `limit`. Multi-repo selections sum
  /// counts so a shared label wins over a label that's hot in just one repo.
  public func topUsed(repositories: [String], limit: Int) -> [String] {
    guard limit > 0, !repositories.isEmpty else { return [] }
    let repoSet = Set(repositories)
    let descriptor = FetchDescriptor<CachedDependencyLabelUsage>()
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

  public func deleteAll() {
    let descriptor = FetchDescriptor<CachedDependencyLabelUsage>()
    guard let rows = try? context.fetch(descriptor) else { return }
    for row in rows {
      context.delete(row)
    }
    try? context.save()
  }
}
