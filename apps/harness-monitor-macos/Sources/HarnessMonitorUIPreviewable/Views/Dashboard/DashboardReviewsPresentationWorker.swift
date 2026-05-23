import Foundation
import HarnessMonitorKit
import OSLog

struct DashboardReviewsItemGroup: Equatable, Identifiable, Sendable {
  enum Kind: Equatable, Sendable {
    case repository(String)
    case status(String)
    case author(String)

    var title: String {
      switch self {
      case .repository(let value): value
      case .status(let value): value
      case .author(let value): value
      }
    }

    var rawValue: String {
      switch self {
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
  }
}

private struct DashboardReviewsListPresentation: Equatable, Sendable {
  static let empty = Self(
    filteredItems: [],
    groupedItems: [],
    relativeUpdatedLabels: [:]
  )

  let filteredItems: [ReviewItem]
  let groupedItems: [DashboardReviewsRepositoryGroup]
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
    let selectedItems = input.items
      .filter { input.selectedIDs.contains($0.pullRequestID) }
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
    let categoryMode = DashboardReviewsCategoryMode(rawValue: input.categoryModeRaw) ?? .all
    let comparator = sortMode.comparator
    let query = input.searchText.trimmingCharacters(in: .whitespacesAndNewlines)

    let filteredItems = input.items
      .filter { categoryMode.matches($0) }
      .filter { filterMode.matches($0) }
      .filter { item in
        guard !query.isEmpty else { return true }
        let haystacks = [
          item.repository,
          item.title,
          item.authorLogin,
          item.labels.joined(separator: " "),
        ]
        return haystacks.joined(separator: " ").localizedCaseInsensitiveContains(query)
      }
      .sorted(by: comparator)

    let groupedItems = Self.groupedItems(
      filteredItems,
      sort: comparator,
      configuredRepositories: input.configuredRepositories,
      configuredOrganizations: input.configuredOrganizations
    )
    return DashboardReviewsListPresentation(
      filteredItems: filteredItems,
      groupedItems: groupedItems,
      relativeUpdatedLabels: relativeUpdatedLabels(for: filteredItems)
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
    sort comparator: (ReviewItem, ReviewItem) -> Bool,
    configuredRepositories: [String],
    configuredOrganizations: [String]
  ) -> [DashboardReviewsRepositoryGroup] {
    let grouped = Dictionary(grouping: filteredItems, by: \.repository)
    let ordering = DashboardReviewsRepositoryOrdering(
      configuredRepositories: configuredRepositories,
      configuredOrganizations: configuredOrganizations
    )
    return
      grouped
      .map { repository, items in
        DashboardReviewsRepositoryGroup(
          kind: .repository(repository),
          items: items.sorted(by: comparator)
        )
      }
      .sorted { ordering.compare($0.repository, $1.repository) }
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
