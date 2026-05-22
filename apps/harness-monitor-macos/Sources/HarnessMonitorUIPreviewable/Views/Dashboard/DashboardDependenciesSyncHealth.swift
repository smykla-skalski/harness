import Foundation

struct DashboardDependenciesSyncHealth: Equatable {
  let totalRepositoryCount: Int
  let syncingRepositoryCount: Int
  let failedRepositories: [String]
  let staleRepositories: [String]

  var hasFailures: Bool {
    !failedRepositories.isEmpty
  }

  var hasStaleRepositories: Bool {
    !staleRepositories.isEmpty
  }

  var summaryLabel: String {
    if hasFailures {
      return "\(failedRepositories.count) sync error(s)"
    }
    if syncingRepositoryCount > 0 {
      return "Syncing \(syncingRepositoryCount)"
    }
    if hasStaleRepositories {
      return "\(staleRepositories.count) stale"
    }
    return "Sync healthy"
  }

  @MainActor
  static func snapshot(
    scheduler: DashboardDependenciesScheduler,
    staleAfterSeconds: TimeInterval,
    now: Date = Date()
  ) -> Self {
    var failed: [String] = []
    var stale: [String] = []
    for (repository, state) in scheduler.states {
      if state.lastErrorMessage != nil {
        failed.append(repository)
      } else if let lastSyncedAt = state.lastSyncedAt {
        if now.timeIntervalSince(lastSyncedAt) >= staleAfterSeconds {
          stale.append(repository)
        }
      } else {
        stale.append(repository)
      }
    }
    return Self(
      totalRepositoryCount: scheduler.states.count,
      syncingRepositoryCount: scheduler.repositoriesInFlight.count,
      failedRepositories: failed.sorted(),
      staleRepositories: stale.sorted()
    )
  }
}
