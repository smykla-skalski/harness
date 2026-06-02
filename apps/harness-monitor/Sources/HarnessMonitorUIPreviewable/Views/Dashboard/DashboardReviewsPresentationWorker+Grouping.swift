import Foundation
import HarnessMonitorKit
import OSLog

extension DashboardReviewsPresentationWorker {
  static func groupedItems(
    _ pinnedPartition: DashboardReviewsPinnedPartition,
    groupMode: DashboardReviewsGroupMode,
    input: DashboardReviewsListPresentationInput
  ) -> [DashboardReviewsRepositoryGroup] {
    switch groupMode {
    case .repository:
      repositoryGroupedItems(
        pinnedPartition,
        configuredRepositories: input.configuredRepositories,
        configuredOrganizations: input.configuredOrganizations,
        pinnedRepositoryIDs: input.pinnedRepositoryIDs
      )
    case .status:
      statusGroupedItems(pinnedPartition.orderedItems)
    case .author:
      authorGroupedItems(
        pinnedPartition.orderedItems,
        configuredAuthors: input.configuredAuthors
      )
    case .smartInbox:
      smartInboxGroupedItems(
        pinnedPartition,
        viewerLogin: input.viewerLogin,
        snoozedPullRequests: input.snoozedPullRequests,
        showSnoozedOnly: input.showSnoozedOnly
      )
    case .flat:
      []
    }
  }

  static func pinnedPartition(
    _ items: [ReviewItem],
    pinnedPullRequestIDs: [String]
  ) -> DashboardReviewsPinnedPartition {
    guard !pinnedPullRequestIDs.isEmpty else {
      return DashboardReviewsPinnedPartition(
        orderedItems: items,
        pinnedItems: [],
        unpinnedItems: items
      )
    }
    let pinned = Set(pinnedPullRequestIDs)
    var pinnedItems: [ReviewItem] = []
    var unpinnedItems: [ReviewItem] = []
    pinnedItems.reserveCapacity(min(items.count, pinned.count))
    unpinnedItems.reserveCapacity(items.count)
    for item in items {
      if pinned.contains(item.pullRequestID) {
        pinnedItems.append(item)
      } else {
        unpinnedItems.append(item)
      }
    }
    guard !pinnedItems.isEmpty else {
      return DashboardReviewsPinnedPartition(
        orderedItems: items,
        pinnedItems: [],
        unpinnedItems: items
      )
    }
    var orderedItems: [ReviewItem] = []
    orderedItems.reserveCapacity(items.count)
    orderedItems.append(contentsOf: pinnedItems)
    orderedItems.append(contentsOf: unpinnedItems)
    return DashboardReviewsPinnedPartition(
      orderedItems: orderedItems,
      pinnedItems: pinnedItems,
      unpinnedItems: unpinnedItems
    )
  }

  private static func repositoryGroupedItems(
    _ pinnedPartition: DashboardReviewsPinnedPartition,
    configuredRepositories: [String],
    configuredOrganizations: [String],
    pinnedRepositoryIDs: [String]
  ) -> [DashboardReviewsRepositoryGroup] {
    let ordering = DashboardReviewsRepositoryOrdering(
      configuredRepositories: configuredRepositories,
      configuredOrganizations: configuredOrganizations
    )
    var grouped: [String: [ReviewItem]] = [:]
    grouped.reserveCapacity(pinnedPartition.unpinnedItems.count)
    for item in pinnedPartition.unpinnedItems {
      grouped[item.repository, default: []].append(item)
    }

    var repositoryGroups: [DashboardReviewsRepositoryGroup] = []
    repositoryGroups.reserveCapacity(grouped.count)
    for (repository, items) in grouped {
      repositoryGroups.append(
        DashboardReviewsRepositoryGroup(
          kind: .repository(repository),
          items: items
        )
      )
    }

    let pinnedSet = Set(pinnedRepositoryIDs)
    repositoryGroups.sort { lhs, rhs in
      let lhsPinned = pinnedSet.contains(lhs.repository)
      let rhsPinned = pinnedSet.contains(rhs.repository)
      if lhsPinned != rhsPinned {
        return lhsPinned
      }
      return ordering.compare(lhs.repository, rhs.repository)
    }

    guard !pinnedPartition.pinnedItems.isEmpty else { return repositoryGroups }
    var groupsWithPinned: [DashboardReviewsRepositoryGroup] = []
    groupsWithPinned.reserveCapacity(repositoryGroups.count + 1)
    groupsWithPinned.append(
      DashboardReviewsRepositoryGroup(kind: .pinned, items: pinnedPartition.pinnedItems)
    )
    groupsWithPinned.append(contentsOf: repositoryGroups)
    return groupsWithPinned
  }

  private static func statusGroupedItems(
    _ filteredItems: [ReviewItem]
  ) -> [DashboardReviewsRepositoryGroup] {
    var grouped: [String: DashboardReviewsStatusGroupAccumulator] = [:]
    grouped.reserveCapacity(filteredItems.count)
    for item in filteredItems {
      grouped[item.statusLabel, default: DashboardReviewsStatusGroupAccumulator()].append(item)
    }

    var candidates: [DashboardReviewsStatusGroupCandidate] = []
    candidates.reserveCapacity(grouped.count)
    for (status, accumulator) in grouped {
      candidates.append(
        DashboardReviewsStatusGroupCandidate(
          group: DashboardReviewsRepositoryGroup(
            kind: .status(status),
            items: accumulator.items
          ),
          minimumBucket: accumulator.minimumBucket
        )
      )
    }
    candidates.sort { lhs, rhs in
      if lhs.minimumBucket != rhs.minimumBucket {
        return lhs.minimumBucket < rhs.minimumBucket
      }
      return lhs.group.kind.title.localizedStandardCompare(rhs.group.kind.title)
        == .orderedAscending
    }

    var groups: [DashboardReviewsRepositoryGroup] = []
    groups.reserveCapacity(candidates.count)
    for candidate in candidates {
      groups.append(candidate.group)
    }
    return groups
  }

  private static func authorGroupedItems(
    _ filteredItems: [ReviewItem],
    configuredAuthors: [String]
  ) -> [DashboardReviewsRepositoryGroup] {
    var grouped: [String: [ReviewItem]] = [:]
    grouped.reserveCapacity(filteredItems.count)
    for item in filteredItems {
      grouped[item.authorLogin, default: []].append(item)
    }

    let ordering = DashboardReviewsAuthorOrdering(configuredAuthors: configuredAuthors)
    var groups: [DashboardReviewsRepositoryGroup] = []
    groups.reserveCapacity(grouped.count)
    for (author, items) in grouped {
      groups.append(
        DashboardReviewsRepositoryGroup(
          kind: .author(author),
          items: items
        )
      )
    }
    groups.sort { ordering.compare($0.kind.title, $1.kind.title) }
    return groups
  }

  private static func smartInboxGroupedItems(
    _ pinnedPartition: DashboardReviewsPinnedPartition,
    viewerLogin: String?,
    snoozedPullRequests: DashboardReviewsSnoozedPullRequests,
    showSnoozedOnly: Bool
  ) -> [DashboardReviewsRepositoryGroup] {
    var buckets = DashboardReviewsSmartInboxBuckets()
    let currentDate = Date.now

    for item in pinnedPartition.unpinnedItems {
      let isSnoozed = snoozedPullRequests.isSnoozed(
        item.pullRequestID,
        currentDate: currentDate,
        currentUpdatedAt: item.updatedAt
      )

      // If we are showing only snoozed items via the toggle, we might not want to force them
      // all into the "Snoozed" bucket, maybe we categorize them normally. But if we want
      // the "Snoozed" bucket, let's put them in it. Or if `showSnoozedOnly == false`, they
      // go into `snoozed` bucket.
      // Let's put all snoozed items in the `snoozed` bucket regardless, since it's Smart Inbox.
      let section =
        isSnoozed
        ? .snoozed
        : dashboardReviewsSmartInboxSection(for: item, viewerLogin: viewerLogin)
      buckets.append(item, to: section)
    }

    return buckets.groups(pinnedItems: pinnedPartition.pinnedItems)
  }
}

private func dashboardReviewsSmartInboxSection(
  for item: ReviewItem,
  viewerLogin: String?
) -> DashboardReviewsSmartInboxSection {
  let _ = viewerLogin
  if DashboardReviewsCategoryMode.dependencies.matches(item) {
    return .dependencies
  }
  if item.viewerIsRequestedReviewer || item.requiresAttention || item.isAutoMergeable
    || item.isAutoApprovable
  {
    return .primaryInbox
  }
  return .monitoring
}

private struct DashboardReviewsSmartInboxBuckets {
  var primaryInbox: [ReviewItem] = []
  var monitoring: [ReviewItem] = []
  var dependencies: [ReviewItem] = []
  var snoozed: [ReviewItem] = []

  mutating func append(_ item: ReviewItem, to section: DashboardReviewsSmartInboxSection) {
    switch section {
    case .primaryInbox: primaryInbox.append(item)
    case .monitoring: monitoring.append(item)
    case .dependencies: dependencies.append(item)
    case .snoozed: snoozed.append(item)
    }
  }

  func groups(pinnedItems: [ReviewItem]) -> [DashboardReviewsRepositoryGroup] {
    var groups: [DashboardReviewsRepositoryGroup] = []
    appendGroup(&groups, kind: .smartInbox(.primaryInbox), items: primaryInbox)
    appendGroup(&groups, kind: .smartInbox(.monitoring), items: monitoring)
    appendGroup(&groups, kind: .smartInbox(.dependencies), items: dependencies)
    appendGroup(&groups, kind: .pinned, items: pinnedItems)
    appendGroup(&groups, kind: .smartInbox(.snoozed), items: snoozed)
    return groups
  }

  private func appendGroup(
    _ groups: inout [DashboardReviewsRepositoryGroup],
    kind: DashboardReviewsRepositoryGroup.Kind,
    items: [ReviewItem]
  ) {
    guard !items.isEmpty else { return }
    groups.append(DashboardReviewsRepositoryGroup(kind: kind, items: items))
  }
}
