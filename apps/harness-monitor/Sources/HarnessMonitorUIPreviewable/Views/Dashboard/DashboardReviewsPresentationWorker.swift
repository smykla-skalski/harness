import Foundation
import HarnessMonitorKit
import OSLog

struct DashboardReviewsItemGroup: Equatable, Identifiable, Sendable {
  enum Kind: Equatable, Sendable {
    case pinned
    case repository(String)
    case status(String)
    case author(String)

    var title: String {
      switch self {
      case .pinned: "Pinned"
      case .repository(let value): value
      case .status(let value): value
      case .author(let value): value
      }
    }

    var rawValue: String {
      switch self {
      case .pinned: "pinned"
      case .repository(let value): "repository:\(value)"
      case .status(let value): "status:\(value)"
      case .author(let value): "author:\(value)"
      }
    }
  }

  let kind: Kind
  let items: [ReviewItem]

  var id: String { kind.rawValue }

  // Back-compat accessor for callers that only handle repository groups.
  var repository: String {
    if case .repository(let value) = kind { return value }
    return ""
  }
}

typealias DashboardReviewsRepositoryGroup = DashboardReviewsItemGroup

struct DashboardReviewsPresentationInput: Equatable, Sendable {
  let items: [ReviewItem]
  let filterModeRaw: String
  let sortModeRaw: String
  let groupModeRaw: String
  let categoryModeRaw: String
  let searchText: String
  let configuredRepositories: [String]
  let configuredOrganizations: [String]
  let configuredAuthors: [String]
  let selectedIDs: Set<String>
  let persistedPrimarySelectionID: String
  let pinnedPullRequestIDs: [String]
  let needsMeOn: Bool
  let dependenciesOnlyOn: Bool

  init(
    items: [ReviewItem],
    filterModeRaw: String,
    sortModeRaw: String,
    groupModeRaw: String = DashboardReviewsGroupMode.repository.rawValue,
    categoryModeRaw: String,
    searchText: String,
    configuredRepositories: [String],
    configuredOrganizations: [String],
    configuredAuthors: [String] = [],
    selectedIDs: Set<String>,
    persistedPrimarySelectionID: String,
    pinnedPullRequestIDs: [String] = [],
    needsMeOn: Bool = false,
    dependenciesOnlyOn: Bool = false
  ) {
    self.items = items
    self.filterModeRaw = filterModeRaw
    self.sortModeRaw = sortModeRaw
    self.groupModeRaw = groupModeRaw
    self.categoryModeRaw = categoryModeRaw
    self.searchText = searchText
    self.configuredRepositories = configuredRepositories
    self.configuredOrganizations = configuredOrganizations
    self.configuredAuthors = configuredAuthors
    self.selectedIDs = selectedIDs
    self.persistedPrimarySelectionID = persistedPrimarySelectionID
    self.pinnedPullRequestIDs = pinnedPullRequestIDs
    self.needsMeOn = needsMeOn
    self.dependenciesOnlyOn = dependenciesOnlyOn
  }
}

private struct DashboardReviewsListPresentationInput: Equatable, Sendable {
  let items: [ReviewItem]
  let filterModeRaw: String
  let sortModeRaw: String
  let groupModeRaw: String
  let categoryModeRaw: String
  let searchText: String
  let configuredRepositories: [String]
  let configuredOrganizations: [String]
  let configuredAuthors: [String]
  let pinnedPullRequestIDs: [String]
  let needsMeOn: Bool
  let dependenciesOnlyOn: Bool

  init(_ input: DashboardReviewsPresentationInput) {
    items = input.items
    filterModeRaw = input.filterModeRaw
    sortModeRaw = input.sortModeRaw
    groupModeRaw = input.groupModeRaw
    categoryModeRaw = input.categoryModeRaw
    searchText = input.searchText
    configuredRepositories = input.configuredRepositories
    configuredOrganizations = input.configuredOrganizations
    configuredAuthors = input.configuredAuthors
    pinnedPullRequestIDs = input.pinnedPullRequestIDs
    needsMeOn = input.needsMeOn
    dependenciesOnlyOn = input.dependenciesOnlyOn
  }
}

private struct DashboardReviewsListPresentation: Equatable, Sendable {
  static let empty = Self(
    filteredItems: [],
    groupedItems: [],
    itemsByID: [:],
    relativeUpdatedLabels: [:]
  )

  let filteredItems: [ReviewItem]
  let groupedItems: [DashboardReviewsRepositoryGroup]
  let itemsByID: [String: ReviewItem]
  let relativeUpdatedLabels: [String: String]
}

struct DashboardReviewsPresentation: Equatable, Sendable {
  static let empty = Self(
    filteredItems: [],
    groupedItems: [],
    selectedItems: [],
    primaryDetailItem: nil,
    relativeUpdatedLabels: [:]
  )

  let filteredItems: [ReviewItem]
  let groupedItems: [DashboardReviewsRepositoryGroup]
  let selectedItems: [ReviewItem]
  let primaryDetailItem: ReviewItem?
  let relativeUpdatedLabels: [String: String]
}

actor DashboardReviewsPresentationWorker {
  private static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf"
  )

  private let isoFormatter = ISO8601DateFormatter()
  private let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter
  }()
  private var cachedListInput: DashboardReviewsListPresentationInput?
  private var cachedListPresentation = DashboardReviewsListPresentation.empty

  func compute(
    input: DashboardReviewsPresentationInput
  ) -> DashboardReviewsPresentation {
    let listInput = DashboardReviewsListPresentationInput(input)
    let listPresentation = computeListPresentation(input: listInput)
    let sortMode = DashboardReviewsSortMode(rawValue: input.sortModeRaw) ?? .status
    let comparator = sortMode.comparator
    let selectedItems = input.selectedIDs
      .compactMap { listPresentation.itemsByID[$0] }
      .sorted(by: comparator)
    return DashboardReviewsPresentation(
      filteredItems: listPresentation.filteredItems,
      groupedItems: listPresentation.groupedItems,
      selectedItems: selectedItems,
      primaryDetailItem: Self.primaryDetailItem(
        selectedItems: selectedItems,
        filteredItems: listPresentation.filteredItems,
        persistedPrimarySelectionID: input.persistedPrimarySelectionID
      ),
      relativeUpdatedLabels: listPresentation.relativeUpdatedLabels
    )
  }

  func waitForIdle() async {}

  private func computeListPresentation(
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

    let filteredItems = input.items
      .filter { categoryMode.matches($0) }
      .filter { filterMode.matches($0) }
      .filter { item in
        guard needsMeOn else { return true }
        return item.requiresAttention
      }
      .filter { item in
        guard dependenciesOnlyOn else { return true }
        return DashboardReviewsCategoryMode.dependencies.matches(item)
      }
      .filter { item in
        guard !query.isEmpty else { return true }
        return item.repository.localizedCaseInsensitiveContains(query)
          || item.title.localizedCaseInsensitiveContains(query)
          || item.authorLogin.localizedCaseInsensitiveContains(query)
          || item.labels.contains { $0.localizedCaseInsensitiveContains(query) }
      }
      .sorted(by: comparator)

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
      itemsByID: Dictionary(
        input.items.map { ($0.pullRequestID, $0) },
        uniquingKeysWith: { first, _ in first }
      ),
      relativeUpdatedLabels: relativeUpdatedLabels(for: pinnedItemsFirst)
    )
  }

  private func relativeUpdatedLabels(
    for items: [ReviewItem],
    relativeTo now: Date = .now
  ) -> [String: String] {
    Dictionary(
      items.map { item -> (String, String) in
        guard let date = isoFormatter.date(from: item.updatedAt) else {
          return (item.pullRequestID, item.updatedAt)
        }
        return (
          item.pullRequestID,
          relativeFormatter.localizedString(for: date, relativeTo: now)
        )
      },
      uniquingKeysWith: { _, last in last }
    )
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
      statusGroupedItems(filteredItems, sort: comparator)
    case .author:
      authorGroupedItems(
        filteredItems,
        sort: comparator,
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
    let pinnedItems = filteredItems.filter { pinned.contains($0.pullRequestID) }
    let repositoryItems = filteredItems.filter { !pinned.contains($0.pullRequestID) }
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
    _ filteredItems: [ReviewItem],
    sort comparator: (ReviewItem, ReviewItem) -> Bool
  ) -> [DashboardReviewsRepositoryGroup] {
    Dictionary(grouping: filteredItems, by: \.statusLabel)
      .map { status, items in
        DashboardReviewsRepositoryGroup(
          kind: .status(status),
          items: items.sorted(by: comparator)
        )
      }
      .sorted { lhs, rhs in
        let lhsBucket = lhs.items.map { $0.statusOrderKey.bucket }.min() ?? Int.max
        let rhsBucket = rhs.items.map { $0.statusOrderKey.bucket }.min() ?? Int.max
        if lhsBucket != rhsBucket { return lhsBucket < rhsBucket }
        return lhs.kind.title.localizedStandardCompare(rhs.kind.title) == .orderedAscending
      }
  }

  private static func authorGroupedItems(
    _ filteredItems: [ReviewItem],
    sort comparator: (ReviewItem, ReviewItem) -> Bool,
    configuredAuthors: [String]
  ) -> [DashboardReviewsRepositoryGroup] {
    let grouped = Dictionary(grouping: filteredItems, by: \.authorLogin)
    let ordering = DashboardReviewsAuthorOrdering(configuredAuthors: configuredAuthors)
    return
      grouped
      .map { author, items in
        DashboardReviewsRepositoryGroup(
          kind: .author(author),
          items: items.sorted(by: comparator)
        )
      }
      .sorted { ordering.compare($0.kind.title, $1.kind.title) }
  }

  private static func primaryDetailItem(
    selectedItems: [ReviewItem],
    filteredItems: [ReviewItem],
    persistedPrimarySelectionID: String
  ) -> ReviewItem? {
    if selectedItems.count == 1 {
      return selectedItems.first
    }
    if selectedItems.isEmpty, !persistedPrimarySelectionID.isEmpty {
      return filteredItems.first { $0.pullRequestID == persistedPrimarySelectionID }
    }
    return selectedItems.isEmpty ? filteredItems.first : nil
  }
}
