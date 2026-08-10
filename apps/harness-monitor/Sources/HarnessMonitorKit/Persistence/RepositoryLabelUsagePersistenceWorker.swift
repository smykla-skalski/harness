import Foundation
import SwiftData

actor RepositoryLabelUsagePersistenceWorker {
  private let modelContainer: ModelContainer
  private let beforePrune: @Sendable () async -> Void

  init(
    modelContainer: ModelContainer,
    beforePrune: @escaping @Sendable () async -> Void = {}
  ) {
    self.modelContainer = modelContainer
    self.beforePrune = beforePrune
  }

  func recordUses(repositories: [String], label: String) {
    guard !label.isEmpty else { return }
    let countsByRepository = repositories.reduce(into: [String: Int]()) { counts, repository in
      guard !repository.isEmpty else { return }
      counts[repository, default: 0] += 1
    }
    guard !countsByRepository.isEmpty else { return }
    let context = ModelContext(modelContainer)
    context.autosaveEnabled = false
    do {
      for repository in countsByRepository.keys.sorted() {
        try recordUse(
          repository: repository,
          label: label,
          increment: countsByRepository[repository] ?? 0,
          context: context
        )
      }
      try context.save()
    } catch {
      HarnessMonitorLogger.store.warning(
        """
        Failed to record review label usage; \
        label=\(label, privacy: .public) \
        error=\(String(reflecting: error), privacy: .public)
        """
      )
    }
  }

  func deleteAll() {
    let context = ModelContext(modelContainer)
    let descriptor = FetchDescriptor<CachedReviewLabelUsage>()
    guard let rows = try? context.fetch(descriptor) else { return }
    for row in rows {
      context.delete(row)
    }
    try? context.save()
  }

  func pruneStale(perRepoCap: Int = 50) async {
    await beforePrune()
    let context = ModelContext(modelContainer)
    RepositoryLabelUsageCacheMaintenance(context: context).pruneStale(
      perRepoCap: perRepoCap
    )
  }

  private func recordUse(
    repository: String,
    label: String,
    increment: Int,
    context: ModelContext
  ) throws {
    let key = CachedReviewLabelUsage.makeCompoundKey(repository: repository, label: label)
    let descriptor = FetchDescriptor<CachedReviewLabelUsage>(
      predicate: #Predicate { $0.compoundKey == key }
    )
    if let existing = try context.fetch(descriptor).first {
      existing.usageCount += increment
      existing.lastUsedAt = .now
    } else {
      let row = CachedReviewLabelUsage(repository: repository, label: label)
      row.usageCount = increment
      context.insert(row)
    }
  }
}
