import HarnessMonitorKit
import SwiftUI

/// Files-section prefetch companion for `DashboardReviewsRouteView`.
/// Keep the single selected PR warm for a likely Files-mode switch, but avoid
/// broad eager fetches when the user multi-selects rows for batch actions.
extension DashboardReviewsRouteView {
  /// Called from `.onChange(of: selectedIDs)` with the diff `added`.
  /// Idempotent — duplicate calls for the same PR are deduped by the
  /// store's `pendingFetches` set. Only the single-primary selection path
  /// prefetches metadata; batch selections stay lazy.
  func prefetchSelectedFiles(adding added: Set<String>) {
    guard normalizedPreferences.filesEnabled,
      added.count == 1,
      let pullRequestID = added.first
    else {
      return
    }
    Task { @MainActor [store] in
      await store.prepareReviewFiles(pullRequestID: pullRequestID)
    }
  }
}
