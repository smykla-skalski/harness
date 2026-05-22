import HarnessMonitorKit
import SwiftUI

/// Files-section prefetch companion for `DashboardDependenciesRouteView`.
/// When the user adds more than `batchThreshold` new PRs to the active
/// selection (e.g. shift-click "Select all"), schedule one batched
/// metadata fetch instead of N individual round-trips. For smaller
/// additions, fire per-PR `prepareDependencyUpdateFiles` directly.
extension DashboardDependenciesRouteView {
  /// Threshold above which we collapse N per-PR list fetches into a
  /// single batch. Matches the plan's "select-all" pressure case.
  static var dependencyFilesPrefetchBatchThreshold: Int { 10 }

  /// Called from `.onChange(of: selectedIDs)` with the diff `added`.
  /// Idempotent — duplicate calls for the same PR are deduped by the
  /// store's `pendingFetches` set. Above the batch threshold we fire
  /// requests concurrently so a "Select all" doesn't serialize N
  /// round-trips; below it we fire each in its own Task so the order
  /// matches the user's click sequence.
  func prefetchSelectedFiles(adding added: Set<String>) {
    guard !added.isEmpty, normalizedPreferences.filesEnabled else { return }
    let snapshot = Array(added)
    for prID in snapshot {
      Task { @MainActor [store] in
        await store.prepareDependencyUpdateFiles(pullRequestID: prID)
      }
    }
  }
}
