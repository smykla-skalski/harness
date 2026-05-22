import Foundation
import Observation

/// Per-PR observable surface for the Reviews detail-pane timeline.
///
/// Storing entries on a per-PR `@Observable` rather than on the global
/// `HarnessMonitorStore` keeps view invalidation scoped to the open
/// detail pane — sibling list rows and other open PR detail panes do
/// not re-evaluate when this view model mutates. The store caches a
/// non-observed dictionary of these instances so resolving one for an
/// already-seen PR does not invalidate every reader.
@Observable
@MainActor
public final class ReviewTimelineViewModel {
  public var entries: [ReviewTimelineEntry] = []
  public private(set) var revision: UInt64 = 0
  public var startCursor: String?
  public var endCursor: String?
  public var hasOlder: Bool = false
  public var hasNewer: Bool = false
  public var viewerCanComment: Bool = true
  public var loadState: LoadState = .idle
  public var lastError: String?
  public var fetchedAt: String?

  public init() {}

  public enum LoadState: Equatable, Sendable {
    case idle
    case loadingInitial
    case loadingOlder
    case refreshing
    case failed
  }

  /// Replaces the timeline with the fully-drained page returned by the
  /// daemon. `loadState` settles to `.idle` and `lastError` clears so
  /// the view can drop any "Retry" affordance.
  public func apply(initial response: ReviewsTimelineResponse) {
    entries = response.entries
    bumpRevision()
    startCursor = response.pageInfo.startCursor
    endCursor = response.pageInfo.endCursor
    hasOlder = response.pageInfo.hasOlder
    hasNewer = response.pageInfo.hasNewer
    viewerCanComment = response.viewerCanComment
    fetchedAt = response.fetchedAt
    loadState = .idle
    lastError = nil
  }

  /// Prepends an older page to the existing entries (older entries
  /// pushed onto the front; UI displays newest-first). Updates the
  /// cursor and `hasOlder` flags so subsequent "Load older" requests
  /// pick up where this one left off.
  public func appendOlder(_ response: ReviewsTimelineResponse) {
    entries.insert(contentsOf: response.entries, at: 0)
    bumpRevision()
    if response.pageInfo.startCursor != nil {
      startCursor = response.pageInfo.startCursor
    }
    hasOlder = response.pageInfo.hasOlder
    fetchedAt = response.fetchedAt
    loadState = .idle
    lastError = nil
  }

  public func markLoading(_ state: LoadState) {
    loadState = state
  }

  public func markFailed(reason: String) {
    loadState = .failed
    lastError = reason
  }

  public func clear() {
    entries.removeAll()
    bumpRevision()
    startCursor = nil
    endCursor = nil
    hasOlder = false
    hasNewer = false
    fetchedAt = nil
    loadState = .idle
    lastError = nil
  }

  /// Appends an optimistic entry — typically the just-sent comment —
  /// to the end of the timeline so the UI reflects the user's action
  /// before the daemon roundtrip completes. The caller keeps the
  /// returned id and either lets the optimistic entry stand (the
  /// daemon's cache append covers the next fetch) or removes it via
  /// `removeOptimistic(id:)` on failure.
  public func appendOptimistic(_ entry: ReviewTimelineEntry) {
    entries.append(entry)
    bumpRevision()
  }

  /// Removes a previously-appended optimistic entry, used after a
  /// failed Send so the UI doesn't show a comment that never landed.
  public func removeOptimistic(id: String) {
    entries.removeAll { $0.id == id }
    bumpRevision()
  }

  /// Replaces a synthetic optimistic entry with the real GitHub-returned
  /// timeline entry. If the optimistic entry has already disappeared, appends
  /// the real entry unless it is already present.
  public func replaceOptimistic(id: String, with entry: ReviewTimelineEntry) {
    if let index = entries.firstIndex(where: { $0.id == id }) {
      entries[index] = entry
    } else if !entries.contains(where: { $0.id == entry.id }) {
      entries.append(entry)
    }
    bumpRevision()
  }

  /// Returns the current `isResolved` flag for the review thread with
  /// the given GraphQL node id, or `nil` if no matching entry is in
  /// the timeline. Used by the store's optimistic-toggle path to
  /// snapshot the prior state before the daemon round-trip so a
  /// failed mutation can revert cleanly.
  public func threadResolvedState(threadID: String) -> Bool? {
    for entry in entries {
      if case .reviewThread(let payload) = entry, payload.id == threadID {
        return payload.isResolved
      }
    }
    return nil
  }

  /// Mutates the in-memory review-thread entry's `isResolved` flag.
  /// Called by the store immediately after the user toggles the
  /// Resolve / Unresolve button (before the daemon round-trip), and
  /// again on success to reconcile against the server-side echo
  /// when it differs from the optimistic value.
  public func updateReviewThreadResolved(threadID: String, resolved: Bool) {
    var changed = false
    for index in entries.indices {
      if case .reviewThread(let payload) = entries[index], payload.id == threadID {
        entries[index] = .reviewThread(payload.updatingResolved(to: resolved))
        changed = true
      }
    }
    if changed {
      bumpRevision()
    }
  }

  private func bumpRevision() {
    revision &+= 1
  }
}
