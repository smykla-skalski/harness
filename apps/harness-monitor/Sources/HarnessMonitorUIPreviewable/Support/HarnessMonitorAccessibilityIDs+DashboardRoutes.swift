extension HarnessMonitorAccessibility {
  public static let dashboardDiagnosticsRoot = "harness.dashboard.diagnostics"
  public static let dashboardReviewsRoot = "harness.dashboard.reviews"
  public static let dashboardReviewsProvenance =
    "harness.dashboard.reviews.provenance"
  public static let dashboardReviewsList = "harness.dashboard.reviews.list"
  public static let dashboardReviewsInContentSearch =
    "harness.dashboard.reviews.in-content-search"
  public static let dashboardReviewsDetail = "harness.dashboard.reviews.detail"
  public static let dashboardReviewsDetailDivider =
    "harness.dashboard.reviews.content-detail-divider"
  public static let dashboardReviewsRefreshButton = "harness.dashboard.reviews.refresh"
  public static let dashboardReviewsInfoButton = "harness.dashboard.reviews.toolbar-info"
  public static let dashboardReviewsPinnedSectionHeader =
    "harness.dashboard.reviews.section.pinned"
  public static let reviewsRefreshSelectedButton =
    "harness.dashboard.reviews.refresh-selected"
  public static let dashboardReviewsConfigureButton =
    "harness.dashboard.reviews.configure"
  public static let dashboardReviewsFixCIButton = "harness.dashboard.reviews.fix-ci"
  public static let dashboardReviewsCustomLabelSheet =
    "harness.dashboard.reviews.custom-label.sheet"
  public static let dashboardReviewsCustomLabelField =
    "harness.dashboard.reviews.custom-label.field"
  public static let dashboardReviewsCustomLabelCancel =
    "harness.dashboard.reviews.custom-label.cancel"
  public static let dashboardReviewsCustomLabelApply =
    "harness.dashboard.reviews.custom-label.apply"
  public static let dashboardReviewsSelectionStatus =
    "harness.dashboard.reviews.selection"
  public static let dashboardReviewsDescription =
    "harness.dashboard.reviews.description"
  public static let dashboardReviewsFilterPicker =
    "harness.dashboard.reviews.filter"
  public static let dashboardReviewsSortPicker =
    "harness.dashboard.reviews.sort"
  public static let dashboardReviewsGroupPicker =
    "harness.dashboard.reviews.group"
  public static let dashboardReviewsCategoryToggle =
    "harness.dashboard.reviews.category"
  public static let dashboardReviewsNeedsMeToggle =
    "harness.dashboard.reviews.needs-me"
  public static let dashboardReviewsShowRowAvatarsToggle =
    "harness.dashboard.reviews.show-row-avatars"
  public static let dashboardReviewsShowRowLabelsToggle =
    "harness.dashboard.reviews.show-row-labels"
  public static let dashboardReviewsShowRowLineCountersToggle =
    "harness.dashboard.reviews.show-row-line-counters"
  public static let dashboardReviewsRefreshTimeoutBanner =
    "harness.dashboard.reviews.refresh-timeout-banner"
  public static let dashboardReviewsTimeoutRetryButton =
    "harness.dashboard.reviews.refresh-timeout-retry"
  public static let dashboardReviewsTimeoutDismissButton =
    "harness.dashboard.reviews.refresh-timeout-dismiss"
  public static let dashboardReviewsRefreshTimeoutToast =
    "harness.dashboard.reviews.refresh-timeout-toast"

  public static func dashboardReviewPinnedIndicator(_ pullRequestID: String) -> String {
    "harness.dashboard.reviews.pinned.\(slug(pullRequestID))"
  }
}
