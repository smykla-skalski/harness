import Foundation
import HarnessMonitorKit
import OSLog

private struct DashboardReviewsFilterCriteria {
  let categoryMode: DashboardReviewsCategoryMode
  let filterMode: DashboardReviewsFilterMode
  let needsMeOn: Bool
  let dependenciesOnlyOn: Bool
  let query: String
}

private struct DashboardReviewsRelativeLabelCacheKey: Hashable {
  let pullRequestID: String
  let updatedAt: String
  let minuteBucket: Int64
}

private struct DashboardReviewsStatusGroupAccumulator {
  var items: [ReviewItem] = []
  var minimumBucket = Int.max

  mutating func append(_ item: ReviewItem) {
    items.append(item)
    minimumBucket = min(minimumBucket, item.statusOrderKey.bucket)
  }
}

private struct DashboardReviewsStatusGroupCandidate {
  let group: DashboardReviewsRepositoryGroup
  let minimumBucket: Int
}

actor DashboardReviewsPresentationWorker {
  private static let relativeLabelCacheLimit = 4_096
  private static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf"
  )

  private var isoFormatterStorage: ISO8601DateFormatter?
  private var relativeFormatterStorage: RelativeDateTimeFormatter?
  private var cachedListInput: DashboardReviewsListPresentationInput?
  private var cachedListPresentation = DashboardReviewsListPresentation.empty
  private var relativeLabelCache: [DashboardReviewsRelativeLabelCacheKey: String] = [:]
  private var relativeLabelCacheOrder: [DashboardReviewsRelativeLabelCacheKey] = []

  func compute(
    input: DashboardReviewsPresentationInput
  ) -> DashboardReviewsPresentation {
    let listInput = DashboardReviewsListPresentationInput(input)
    let listPresentation = computeList(input: listInput)
    return DashboardReviewsPresentation(
      listPresentation: listPresentation,
      selectedIDs: input.selectedIDs,
      persistedPrimarySelectionID: input.persistedPrimarySelectionID,
      sortModeRaw: input.sortModeRaw
    )
  }

  func waitForIdle() async {}

  func computeList(
    input: DashboardReviewsListPresentationInput
  ) -> DashboardReviewsListPresentation {
    guard input != cachedListInput else {
      return cachedListPresentation
    }
    let signpostID = Self.signposter.makeSignpostID()
    let interval = Self.signposter.beginInterval(
      "dashboard_reviews.presentation.compute",
      id: signpostID,
      "items=\(input.items.count, privacy: .public)"
    )
    defer {
      Self.signposter.endInterval(
        "dashboard_reviews.presentation.compute",
        interval,
        "visible=\(self.cachedListPresentation.filteredItems.count, privacy: .public)"
      )
    }
    cachedListInput = input
    cachedListPresentation = listPresentation(from: input)
    return cachedListPresentation
  }

  private func listPresentation(
    from input: DashboardReviewsListPresentationInput
  ) -> DashboardReviewsListPresentation {
    let filterMode = DashboardReviewsFilterMode(rawValue: input.filterModeRaw) ?? .all
    let sortMode = DashboardReviewsSortMode(rawValue: input.sortModeRaw) ?? .status
    let groupMode = DashboardReviewsGroupMode(rawValue: input.groupModeRaw) ?? .repository
    let categoryMode = DashboardReviewsCategoryMode(rawValue: input.categoryModeRaw) ?? .all
    let comparator = sortMode.comparator
    let query = input.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let needsMeOn = input.needsMeOn
    let dependenciesOnlyOn = input.dependenciesOnlyOn
    let filterCriteria = DashboardReviewsFilterCriteria(
      categoryMode: categoryMode,
      filterMode: filterMode,
      needsMeOn: needsMeOn,
      dependenciesOnlyOn: dependenciesOnlyOn,
      query: query
    )

    var filteredItems = Self.filteredItems(
      from: input.items,
      matching: filterCriteria
    )
    filteredItems.sort(by: comparator)

    let pinnedItemsFirst = Self.pinnedItemsFirst(
      filteredItems,
      pinnedPullRequestIDs: input.pinnedPullRequestIDs
    )

    let groupedItems = Self.groupedItems(
      pinnedItemsFirst,
      groupMode: groupMode,
      sort: comparator,
      input: input
    )
    return DashboardReviewsListPresentation(
      filteredItems: pinnedItemsFirst,
      groupedItems: groupedItems,
      itemsByID: Self.itemsByID(for: input.items),
      relativeUpdatedLabels: relativeUpdatedLabels(for: pinnedItemsFirst),
      version: DashboardReviewsListPresentationVersion(input: input)
    )
  }

  private static func filteredItems(
    from items: [ReviewItem],
    matching criteria: DashboardReviewsFilterCriteria
  ) -> [ReviewItem] {
    let hasQuery = !criteria.query.isEmpty
    var filteredItems: [ReviewItem] = []
    filteredItems.reserveCapacity(items.count)

    for item in items {
      guard criteria.categoryMode.matches(item), criteria.filterMode.matches(item) else {
        continue
      }
      if criteria.needsMeOn, !item.requiresAttention {
        continue
      }
      if criteria.dependenciesOnlyOn, !DashboardReviewsCategoryMode.dependencies.matches(item) {
        continue
      }
      if hasQuery, !item.matchesDashboardReviewsQuery(criteria.query) {
        continue
      }
      filteredItems.append(item)
    }

    return filteredItems
  }

  private static func itemsByID(for items: [ReviewItem]) -> [String: ReviewItem] {
    var result: [String: ReviewItem] = [:]
    result.reserveCapacity(items.count)
    for item in items where result[item.pullRequestID] == nil {
      result[item.pullRequestID] = item
    }
    return result
  }

  private func relativeUpdatedLabels(
    for items: [ReviewItem],
    relativeTo now: Date = .now
  ) -> [String: String] {
    guard !items.isEmpty else {
      return [:]
    }

    let isoFormatter = isoFormatter
    let relativeFormatter = relativeFormatter
    let minuteBucket = Self.relativeLabelMinuteBucket(for: now)
    var result: [String: String] = [:]
    result.reserveCapacity(items.count)
    for item in items {
      let key = DashboardReviewsRelativeLabelCacheKey(
        pullRequestID: item.pullRequestID,
        updatedAt: item.updatedAt,
        minuteBucket: minuteBucket
      )
      if let cached = relativeLabelCache[key] {
        result[item.pullRequestID] = cached
        continue
      }
      let label = relativeUpdatedLabel(
        for: item,
        relativeTo: now,
        isoFormatter: isoFormatter,
        relativeFormatter: relativeFormatter
      )
      relativeLabelCache[key] = label
      relativeLabelCacheOrder.append(key)
      result[item.pullRequestID] = label
    }
    pruneRelativeLabelCacheIfNeeded()
    return result
  }

  private var isoFormatter: ISO8601DateFormatter {
    if let isoFormatterStorage {
      return isoFormatterStorage
    }
    let formatter = ISO8601DateFormatter()
    isoFormatterStorage = formatter
    return formatter
  }

  private var relativeFormatter: RelativeDateTimeFormatter {
    if let relativeFormatterStorage {
      return relativeFormatterStorage
    }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    relativeFormatterStorage = formatter
    return formatter
  }

  private func relativeUpdatedLabel(
    for item: ReviewItem,
    relativeTo now: Date,
    isoFormatter: ISO8601DateFormatter,
    relativeFormatter: RelativeDateTimeFormatter
  ) -> String {
    guard let date = isoFormatter.date(from: item.updatedAt) else {
      return item.updatedAt
    }
    return relativeFormatter.localizedString(for: date, relativeTo: now)
  }

  private func pruneRelativeLabelCacheIfNeeded() {
    let overflow = relativeLabelCacheOrder.count - Self.relativeLabelCacheLimit
    guard overflow > 0 else { return }
    for key in relativeLabelCacheOrder.prefix(overflow) {
      relativeLabelCache.removeValue(forKey: key)
    }
    relativeLabelCacheOrder.removeFirst(overflow)
  }

  private static func relativeLabelMinuteBucket(for date: Date) -> Int64 {
    Int64(date.timeIntervalSince1970 / 60)
  }

  private static func groupedItems(
    _ filteredItems: [ReviewItem],
    groupMode: DashboardReviewsGroupMode,
    sort comparator: (ReviewItem, ReviewItem) -> Bool,
    input: DashboardReviewsListPresentationInput
  ) -> [DashboardReviewsRepositoryGroup] {
    switch groupMode {
    case .repository:
      repositoryGroupedItems(
        filteredItems,
        configuredRepositories: input.configuredRepositories,
        configuredOrganizations: input.configuredOrganizations,
        pinnedPullRequestIDs: input.pinnedPullRequestIDs
      )
    case .status:
      statusGroupedItems(filteredItems)
    case .author:
      authorGroupedItems(
        filteredItems,
        configuredAuthors: input.configuredAuthors
      )
    case .flat:
      []
    }
  }

  private static func pinnedItemsFirst(
    _ items: [ReviewItem],
    pinnedPullRequestIDs: [String]
  ) -> [ReviewItem] {
    guard !pinnedPullRequestIDs.isEmpty else { return items }
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
    guard !pinnedItems.isEmpty else { return items }
    return pinnedItems + unpinnedItems
  }

  private static func repositoryGroupedItems(
    _ filteredItems: [ReviewItem],
    configuredRepositories: [String],
    configuredOrganizations: [String],
    pinnedPullRequestIDs: [String]
  ) -> [DashboardReviewsRepositoryGroup] {
    let pinned = Set(pinnedPullRequestIDs)
    var pinnedItems: [ReviewItem] = []
    var repositoryItems: [ReviewItem] = []
    pinnedItems.reserveCapacity(min(filteredItems.count, pinned.count))
    repositoryItems.reserveCapacity(filteredItems.count)
    for item in filteredItems {
      if pinned.contains(item.pullRequestID) {
        pinnedItems.append(item)
      } else {
        repositoryItems.append(item)
      }
    }
    let ordering = DashboardReviewsRepositoryOrdering(
      configuredRepositories: configuredRepositories,
      configuredOrganizations: configuredOrganizations
    )
    var grouped: [String: [ReviewItem]] = [:]
    grouped.reserveCapacity(repositoryItems.count)
    for item in repositoryItems {
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
    repositoryGroups.sort { ordering.compare($0.repository, $1.repository) }

    guard !pinnedItems.isEmpty else { return repositoryGroups }
    var groupsWithPinned: [DashboardReviewsRepositoryGroup] = []
    groupsWithPinned.reserveCapacity(repositoryGroups.count + 1)
    groupsWithPinned.append(DashboardReviewsRepositoryGroup(kind: .pinned, items: pinnedItems))
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

}

extension ReviewItem {
  fileprivate func matchesDashboardReviewsQuery(_ query: String) -> Bool {
    repository.localizedCaseInsensitiveContains(query)
      || title.localizedCaseInsensitiveContains(query)
      || authorLogin.localizedCaseInsensitiveContains(query)
      || labels.contains { $0.localizedCaseInsensitiveContains(query) }
  }
}
