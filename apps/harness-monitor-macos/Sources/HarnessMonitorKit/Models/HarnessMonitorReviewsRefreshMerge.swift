import Foundation

/// Merge a targeted refresh response into an existing list of dependency
/// update items.
///
/// - Replaces items whose pull request id matches a refreshed open item.
/// - Drops items whose refreshed state is no longer `.open`.
/// - Drops items whose id is in `missingPullRequestIDs`.
/// - Leaves other items untouched.
public func applyReviewsRefresh(
  to items: [ReviewItem],
  refresh: ReviewsRefreshResponse
) -> [ReviewItem] {
  let currentItems = normalizedReviewItems(items)
  let refreshedItems = normalizedReviewItems(refresh.items)
  let droppedIDs = Set(refresh.missingPullRequestIDs)
  let openItemsByID: [String: ReviewItem] = Dictionary(
    uniqueKeysWithValues:
      refreshedItems
      .filter { $0.state == .open }
      .map { ($0.pullRequestID, $0) }
  )
  let closedIDs = Set(
    refreshedItems.filter { $0.state != .open }.map(\.pullRequestID)
  )
  return currentItems.compactMap { item -> ReviewItem? in
    if droppedIDs.contains(item.pullRequestID) || closedIDs.contains(item.pullRequestID) {
      return nil
    }
    return openItemsByID[item.pullRequestID] ?? item
  }
}
