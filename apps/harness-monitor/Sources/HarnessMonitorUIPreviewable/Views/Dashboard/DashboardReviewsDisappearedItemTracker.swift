import Foundation
import HarnessMonitorKit

/// Detects pull requests that vanish between consecutive reviews refreshes
/// so the route view can capture a low-priority "removed from list" audit
/// entry for each. The tracker is intentionally pure: it does not perform IO,
/// hold SwiftUI state, or know about notification-history persistence. The
/// route view owns one instance, calls `diff(currentItems:)` on each response
/// change, and forwards the returned descriptors to the store's shared
/// notification-history/audit path.
///
/// Wire-up plan:
/// 1. Route view holds `@State var disappearedTracker = DashboardReviewsDisappearedItemTracker()`.
/// 2. On every `onChange(of: response.items)` it calls
///    `disappearedTracker.diff(currentItems: response.items)` and records each
///    descriptor in notification history so audit can display it.
/// 3. The first call after view appearance is a baseline (no audit entries); the
///    tracker swallows it silently.
struct DashboardReviewsDisappearedItemTracker {
  /// Captured snapshot of a previously-seen review row used to build a
  /// human-readable toast when the row disappears.
  struct Snapshot: Equatable {
    let pullRequestID: String
    let repository: String
    let number: UInt64
    let title: String
    /// Terminal state inferred from the last-seen item. The toast copy
    /// uses this to say "merged" vs "closed" vs just "removed" when the
    /// previous state is unknown.
    let lastSeenState: ReviewPullRequestState

    init(item: ReviewItem) {
      pullRequestID = item.pullRequestID
      repository = item.repository
      number = item.number
      title = item.title
      lastSeenState = item.state
    }

    init(
      pullRequestID: String,
      repository: String,
      number: UInt64,
      title: String,
      lastSeenState: ReviewPullRequestState
    ) {
      self.pullRequestID = pullRequestID
      self.repository = repository
      self.number = number
      self.title = title
      self.lastSeenState = lastSeenState
    }
  }

  /// One descriptor per pull request that was previously visible and is no
  /// longer in the current response. Routed to notification history so audit
  /// can surface it without adding more chrome to the reviews route.
  struct Descriptor: Equatable, Identifiable {
    let snapshot: Snapshot
    var id: String { snapshot.pullRequestID }

    /// Toast copy that names the repo, the PR number, and the inferred
    /// terminal state. Falls back to "removed from list" when the last
    /// observed state was still open (e.g. the daemon dropped the row for
    /// scope reasons rather than a merge or close).
    var toastMessage: String {
      let prefix = "PR #\(snapshot.number) in \(snapshot.repository)"
      switch snapshot.lastSeenState {
      case .merged:
        return "\(prefix) merged - removed from list"
      case .closed:
        return "\(prefix) closed - removed from list"
      case .open, .unknown:
        return "\(prefix) removed from list"
      }
    }

    func notificationHistoryEntry(recordedAt: Date) -> NotificationHistoryEntry {
      NotificationHistoryEntry(
        id: "reviews-disappeared-\(id)-\(Int(recordedAt.timeIntervalSince1970))",
        recordedAt: recordedAt,
        updatedAt: recordedAt,
        source: .toast,
        severity: .info,
        status: .dismissed,
        statusText: "Captured for audit only",
        title: "Review removed from list",
        message: toastMessage
      )
    }
  }

  private var snapshotsByID: [String: Snapshot] = [:]
  private var hasBaseline = false

  /// Diffs the current set of items against the last seen set. The first
  /// call after construction (or after `reset()`) establishes a baseline
  /// and returns an empty array so users do not see toasts for items that
  /// simply hadn't been observed yet. Subsequent calls return one
  /// descriptor per disappeared item, in deterministic repository-then-
  /// number order for stable rendering.
  mutating func diff(currentItems: [ReviewItem]) -> [Descriptor] {
    var nextSnapshots: [String: Snapshot] = [:]
    nextSnapshots.reserveCapacity(currentItems.count)
    for item in currentItems {
      nextSnapshots[item.pullRequestID] = Snapshot(item: item)
    }

    guard hasBaseline else {
      snapshotsByID = nextSnapshots
      hasBaseline = true
      return []
    }

    var descriptors: [Descriptor] = []
    for snapshot in snapshotsByID.values where nextSnapshots[snapshot.pullRequestID] == nil {
      descriptors.append(Descriptor(snapshot: snapshot))
    }

    snapshotsByID = nextSnapshots
    guard descriptors.count > 1 else {
      return descriptors
    }
    return descriptors.sorted { lhs, rhs in
      if lhs.snapshot.repository != rhs.snapshot.repository {
        return lhs.snapshot.repository < rhs.snapshot.repository
      }
      return lhs.snapshot.number < rhs.snapshot.number
    }
  }

  /// Drops the baseline so the next diff is treated as a fresh start.
  /// Useful when the user pivots to a different scope and the previous
  /// item set is no longer comparable.
  mutating func reset() {
    snapshotsByID = [:]
    hasBaseline = false
  }
}
