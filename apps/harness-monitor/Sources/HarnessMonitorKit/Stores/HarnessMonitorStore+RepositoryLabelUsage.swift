import Foundation
import SwiftData

extension HarnessMonitorStore {
  static func makeLabelUsageWorker(
    _ modelContainer: ModelContainer?
  ) -> RepositoryLabelUsagePersistenceWorker? {
    modelContainer.map { RepositoryLabelUsagePersistenceWorker(modelContainer: $0) }
  }

  public func recordRepositoryLabelUsage(
    _ label: String,
    repositories: [String]
  ) async {
    await cacheWriteSync.repositoryLabelUsagePersistenceWorker?.recordUses(
      repositories: repositories,
      label: label
    )
  }
}
