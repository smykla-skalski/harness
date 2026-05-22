import Foundation
import Observation

/// Per-PR observable surface for the Dependencies detail-pane timeline.
///
/// Storing entries on a per-PR `@Observable` rather than on the global
/// `HarnessMonitorStore` keeps view invalidation scoped to the open
/// detail pane — sibling list rows and other open PR detail panes do
/// not re-evaluate when this view model mutates. The store caches a
/// non-observed dictionary of these instances so resolving one for an
/// already-seen PR does not invalidate every reader.
@Observable
@MainActor
public final class DependencyUpdateTimelineViewModel {
  public var entries: [DependencyUpdateTimelineEntry] = []
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
  public func apply(initial response: DependencyUpdatesTimelineResponse) {
    entries = response.entries
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
  public func appendOlder(_ response: DependencyUpdatesTimelineResponse) {
    entries.insert(contentsOf: response.entries, at: 0)
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
    startCursor = nil
    endCursor = nil
    hasOlder = false
    hasNewer = false
    fetchedAt = nil
    loadState = .idle
    lastError = nil
  }
}
