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
    let repositories = Set(repositories.filter { !$0.isEmpty })
    guard !repositories.isEmpty else { return }
    let context = ModelContext(modelContainer)
    context.autosaveEnabled = false
    do {
      for repository in repositories {
        try recordUse(repository: repository, label: label, context: context)
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
    context: ModelContext
  ) throws {
    let key = CachedReviewLabelUsage.makeCompoundKey(repository: repository, label: label)
    let descriptor = FetchDescriptor<CachedReviewLabelUsage>(
      predicate: #Predicate { $0.compoundKey == key }
    )
    if let existing = try context.fetch(descriptor).first {
      existing.usageCount += 1
      existing.lastUsedAt = .now
    } else {
      context.insert(CachedReviewLabelUsage(repository: repository, label: label))
    }
  }
}
