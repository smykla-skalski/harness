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

actor DashboardReviewsPresentationWorker {
  private static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf"
  )

  private var isoFormatterStorage: ISO8601DateFormatter?
  private var relativeFormatterStorage: RelativeDateTimeFormatter?
  private var cachedListInput: DashboardReviewsListPresentationInput?
  private var cachedListPresentation = DashboardReviewsListPresentation.empty

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
    var result: [String: String] = [:]
    result.reserveCapacity(items.count)
    for item in items {
      if let date = isoFormatter.date(from: item.updatedAt) {
        result[item.pullRequestID] = relativeFormatter.localizedString(for: date, relativeTo: now)
      } else {
        result[item.pullRequestID] = item.updatedAt
      }
    }
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
    let grouped = Dictionary(grouping: repositoryItems, by: \.repository)
    let ordering = DashboardReviewsRepositoryOrdering(
      configuredRepositories: configuredRepositories,
      configuredOrganizations: configuredOrganizations
    )
    let repositoryGroups =
      grouped
      .map { repository, items in
        DashboardReviewsRepositoryGroup(
          kind: .repository(repository),
          items: items
        )
      }
      .sorted { ordering.compare($0.repository, $1.repository) }

    guard !pinnedItems.isEmpty else { return repositoryGroups }
    return [DashboardReviewsRepositoryGroup(kind: .pinned, items: pinnedItems)] + repositoryGroups
  }

  private static func statusGroupedItems(
    _ filteredItems: [ReviewItem]
  ) -> [DashboardReviewsRepositoryGroup] {
    Dictionary(grouping: filteredItems, by: \.statusLabel)
      .map { status, items in
        DashboardReviewsRepositoryGroup(
          kind: .status(status),
          items: items
        )
      }
      .sorted { lhs, rhs in
        let lhsBucket = Self.minimumStatusBucket(in: lhs.items)
        let rhsBucket = Self.minimumStatusBucket(in: rhs.items)
        if lhsBucket != rhsBucket { return lhsBucket < rhsBucket }
        return lhs.kind.title.localizedStandardCompare(rhs.kind.title) == .orderedAscending
      }
  }

  private static func authorGroupedItems(
    _ filteredItems: [ReviewItem],
    configuredAuthors: [String]
  ) -> [DashboardReviewsRepositoryGroup] {
    let grouped = Dictionary(grouping: filteredItems, by: \.authorLogin)
    let ordering = DashboardReviewsAuthorOrdering(configuredAuthors: configuredAuthors)
    return
      grouped
      .map { author, items in
        DashboardReviewsRepositoryGroup(
          kind: .author(author),
          items: items
        )
      }
      .sorted { ordering.compare($0.kind.title, $1.kind.title) }
  }

  private static func minimumStatusBucket(in items: [ReviewItem]) -> Int {
    var minimum = Int.max
    for item in items {
      let bucket = item.statusOrderKey.bucket
      if bucket < minimum {
        minimum = bucket
      }
    }
    return minimum
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
