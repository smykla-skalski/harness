import Foundation
import SwiftData

public struct RepositoryLabelsCache {
  private let context: ModelContext

  public init(context: ModelContext) {
    self.context = context
  }

  /// Load every cached repository → labels pair. The picker uses this on
  /// view appear so the menu shows labels for any previously-seen repo even
  /// when the daemon is offline.
  public func loadAll() -> [String: [DependencyUpdateRepositoryLabel]] {
    let descriptor = FetchDescriptor<CachedDependencyRepositoryLabels>()
    guard let rows = try? context.fetch(descriptor) else { return [:] }
    var result: [String: [DependencyUpdateRepositoryLabel]] = [:]
    var stale: [CachedDependencyRepositoryLabels] = []
    for row in rows {
      do {
        let labels = try row.decodedLabels()
        if !labels.isEmpty {
          result[row.repository] = labels
        }
      } catch {
        HarnessMonitorLogger.store.warning(
          """
          Failed to decode cached repository labels; \
          repository=\(row.repository, privacy: .public) \
          error=\(String(reflecting: error), privacy: .public)
          """
        )
        stale.append(row)
      }
    }
    if !stale.isEmpty {
      for row in stale { context.delete(row) }
      try? context.save()
    }
    return result
  }

  /// Upsert one row per repository with the freshly fetched labels. Empty
  /// label arrays are skipped so a transient GitHub blip does not wipe a
  /// repo's previously-cached labels.
  public func upsert(_ snapshot: [String: [DependencyUpdateRepositoryLabel]]) {
    guard !snapshot.isEmpty else { return }
    do {
      let existing = try fetchByRepository()
      for (repository, labels) in snapshot {
        guard !labels.isEmpty else { continue }
        if let row = existing[repository] {
          try row.update(labels: labels)
        } else {
          let row = try CachedDependencyRepositoryLabels.make(
            repository: repository,
            labels: labels
          )
          context.insert(row)
        }
      }
      try context.save()
    } catch {
      HarnessMonitorLogger.store.warning(
        """
        Failed to persist repository labels cache; \
        error=\(String(reflecting: error), privacy: .public)
        """
      )
    }
  }

  public func deleteAll() {
    let descriptor = FetchDescriptor<CachedDependencyRepositoryLabels>()
    guard let rows = try? context.fetch(descriptor) else { return }
    for row in rows {
      context.delete(row)
    }
    try? context.save()
  }

  private func fetchByRepository() throws -> [String: CachedDependencyRepositoryLabels] {
    let descriptor = FetchDescriptor<CachedDependencyRepositoryLabels>()
    let rows = try context.fetch(descriptor)
    return Dictionary(uniqueKeysWithValues: rows.map { ($0.repository, $0) })
  }
}
