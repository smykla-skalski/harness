import Foundation

/// Paces full task-board item refreshes.
///
/// One refresh refetches and re-decodes every board row, which costs far more
/// than the 50 ms window the refresh coalescer uses. A `task_board_updated`
/// push carries only a revision and scopes, never the changed rows, so a sync
/// touching dozens of items emits dozens of pushes and each one asks for a
/// whole-board refetch. Without a floor between them those refreshes chain back
/// to back for the length of the sync and the board relayouts never drain.
enum TaskBoardItemsRefreshPacing {
  static let minimumInterval: TimeInterval = 1

  /// Seconds to wait before starting the next push-driven item refresh.
  static func delay(
    lastRefreshAt: Date?,
    now: Date,
    minimumInterval: TimeInterval = minimumInterval
  ) -> TimeInterval {
    guard let lastRefreshAt else {
      return 0
    }
    let elapsed = now.timeIntervalSince(lastRefreshAt)
    // A clock that moved backwards must not park the board refresh.
    guard elapsed >= 0 else {
      return 0
    }
    return max(0, minimumInterval - elapsed)
  }
}
