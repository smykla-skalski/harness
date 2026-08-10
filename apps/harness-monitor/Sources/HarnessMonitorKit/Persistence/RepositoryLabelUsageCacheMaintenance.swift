import Foundation
import SwiftData

enum RepositoryLabelUsagePersistence {
  static let lock = NSLock()
}

struct RepositoryLabelUsageCacheMaintenance {
  private let context: ModelContext

  init(context: ModelContext) {
    self.context = context
  }

  func pruneStale(perRepoCap: Int = 50) {
    RepositoryLabelUsagePersistence.lock.withLock {
      pruneStaleLocked(perRepoCap: perRepoCap)
    }
  }

  private func pruneStaleLocked(perRepoCap: Int) {
    guard perRepoCap > 0 else { return }
    let allRowsDescriptor = FetchDescriptor<CachedReviewLabelUsage>()
    guard let rows = try? context.fetch(allRowsDescriptor) else { return }
    let groupedByRepo = Dictionary(grouping: rows, by: \.repository)
    var didDelete = false
    for repo in groupedByRepo.keys.sorted() {
      guard let repoRows = groupedByRepo[repo], repoRows.count > perRepoCap else { continue }
      let sorted = repoRows.sorted { lhs, rhs in
        if lhs.usageCount != rhs.usageCount {
          return lhs.usageCount > rhs.usageCount
        }
        return lhs.lastUsedAt > rhs.lastUsedAt
      }
      for row in sorted.dropFirst(perRepoCap) {
        context.delete(row)
        didDelete = true
      }
    }
    guard didDelete else { return }
    do {
      try context.save()
    } catch {
      HarnessMonitorLogger.store.warning(
        """
        Failed to save pruneStale; \
        error=\(String(reflecting: error), privacy: .public)
        """
      )
    }
  }
}
