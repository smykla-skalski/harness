import Foundation

/// Back-compat shim for daemon responses to the Reviews surface.
///
/// The `ReviewItem.viewerCanUpdate` decoder defaults to `false` so that
/// the app errs toward "no action" when the field is missing. Daemons
/// older than the wire version that introduced the field never populate
/// it, which would otherwise leave every action control disabled for
/// users on those daemons. This shim re-enables the field when (and only
/// when) the connected daemon predates that wire version.
///
/// Newer daemons emit the field directly and the shim is a no-op.
public enum HarnessMonitorReviewsDaemonNormalizer {
  /// Wire version that introduced `viewerCanUpdate` on `ReviewItem`.
  /// Daemons below this value pre-date the field and need the shim.
  public static let viewerCanUpdateMinimumWireVersion: Int = 2

  /// Returns a copy of `response` with `viewerCanUpdate = true` on every
  /// item when `daemonWireVersion` is below the field's minimum wire
  /// version. Pass `nil` for `daemonWireVersion` when the connected
  /// daemon never reported a wire version - we treat that as "predates
  /// the field" and apply the shim so the user is not silently locked
  /// out of every action.
  public static func normalize(
    response: ReviewsQueryResponse,
    daemonWireVersion: Int?
  ) -> ReviewsQueryResponse {
    guard requiresViewerCanUpdateShim(daemonWireVersion: daemonWireVersion) else {
      return response
    }
    let adjustedItems = response.items.map(applyViewerCanUpdateShim(to:))
    let summary = ReviewsSummary(items: adjustedItems)
    return ReviewsQueryResponse(
      fetchedAt: response.fetchedAt,
      fromCache: response.fromCache,
      summary: summary,
      items: adjustedItems,
      repositoryLabels: response.repositoryLabels,
      viewerLogin: response.viewerLogin
    )
  }

  /// Same shim, applied to the per-PR refresh ingress path. The refresh
  /// response carries a thin `items` array with no summary or label
  /// payload, so the back-compat treatment is just an item map.
  public static func normalize(
    refresh: ReviewsRefreshResponse,
    daemonWireVersion: Int?
  ) -> ReviewsRefreshResponse {
    guard requiresViewerCanUpdateShim(daemonWireVersion: daemonWireVersion) else {
      return refresh
    }
    let adjustedItems = refresh.items.map(applyViewerCanUpdateShim(to:))
    return ReviewsRefreshResponse(
      fetchedAt: refresh.fetchedAt,
      items: adjustedItems,
      missingPullRequestIDs: refresh.missingPullRequestIDs
    )
  }

  /// True when the connected daemon predates `viewerCanUpdate` on
  /// `ReviewItem` and the app should backfill the field to `true`.
  public static func requiresViewerCanUpdateShim(daemonWireVersion: Int?) -> Bool {
    guard let daemonWireVersion else { return true }
    return daemonWireVersion < viewerCanUpdateMinimumWireVersion
  }

  private static func applyViewerCanUpdateShim(to item: ReviewItem) -> ReviewItem {
    guard !item.viewerCanUpdate else { return item }
    return ReviewItem(
      pullRequestID: item.pullRequestID,
      repositoryID: item.repositoryID,
      repository: item.repository,
      number: item.number,
      title: item.title,
      url: item.url,
      authorLogin: item.authorLogin,
      state: item.state,
      mergeable: item.mergeable,
      reviewStatus: item.reviewStatus,
      checkStatus: item.checkStatus,
      policyBlocked: item.policyBlocked,
      isDraft: item.isDraft,
      headSha: item.headSha,
      labels: item.labels,
      checks: item.checks,
      reviews: item.reviews,
      additions: item.additions,
      deletions: item.deletions,
      createdAt: item.createdAt,
      updatedAt: item.updatedAt,
      requiredFailedCheckNames: item.requiredFailedCheckNames,
      viewerCanUpdate: true,
      viewerCanMergeAsAdmin: item.viewerCanMergeAsAdmin
    )
  }
}
