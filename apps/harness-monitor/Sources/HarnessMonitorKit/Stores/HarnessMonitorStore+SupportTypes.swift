import Observation

struct PendingSessionDetailCacheWrite: Sendable {
  let snapshot: SessionCacheService.CachedSessionSnapshot
  let markViewed: Bool
  let preservesTimeline: Bool
}

typealias NotificationHistoryRuntimeActions = [String: @MainActor () async -> Void]
typealias ReviewFilesViewedPending = [String: [String: ReviewFileViewedState]]
