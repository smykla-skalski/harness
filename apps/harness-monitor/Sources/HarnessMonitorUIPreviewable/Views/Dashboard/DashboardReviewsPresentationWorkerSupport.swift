import HarnessMonitorKit

struct DashboardReviewsFilterCriteria {
  let categoryMode: DashboardReviewsCategoryMode
  let filterMode: DashboardReviewsFilterMode
  let needsMeOn: Bool
  let dependenciesOnlyOn: Bool
  let query: String
}

struct DashboardReviewsRelativeLabelCacheKey: Hashable {
  let pullRequestID: String
  let updatedAt: String
  let minuteBucket: Int64
}

struct DashboardReviewsStatusGroupAccumulator {
  var items: [ReviewItem] = []
  var minimumBucket = Int.max

  mutating func append(_ item: ReviewItem) {
    items.append(item)
    minimumBucket = min(minimumBucket, item.statusOrderKey.bucket)
  }
}

struct DashboardReviewsStatusGroupCandidate {
  let group: DashboardReviewsRepositoryGroup
  let minimumBucket: Int
}

struct DashboardReviewsPinnedPartition {
  let orderedItems: [ReviewItem]
  let pinnedItems: [ReviewItem]
  let unpinnedItems: [ReviewItem]
}
