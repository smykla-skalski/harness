import Foundation
import HarnessMonitorKit
import OSLog

struct DashboardDependenciesRepositoryGroup: Equatable, Identifiable, Sendable {
  let repository: String
  let items: [DependencyUpdateItem]

  var id: String { repository }
}

struct DashboardDependenciesPresentationInput: Equatable, Sendable {
  let items: [DependencyUpdateItem]
  let filterModeRaw: String
  let sortModeRaw: String
  let searchText: String
  let configuredRepositories: [String]
  let configuredOrganizations: [String]
  let selectedIDs: Set<String>
  let persistedPrimarySelectionID: String
}

private struct DashboardDependenciesListPresentationInput: Equatable, Sendable {
  let items: [DependencyUpdateItem]
  let filterModeRaw: String
  let sortModeRaw: String
  let searchText: String
  let configuredRepositories: [String]
  let configuredOrganizations: [String]

  init(_ input: DashboardDependenciesPresentationInput) {
    items = input.items
    filterModeRaw = input.filterModeRaw
    sortModeRaw = input.sortModeRaw
    searchText = input.searchText
    configuredRepositories = input.configuredRepositories
    configuredOrganizations = input.configuredOrganizations
  }
}

private struct DashboardDependenciesListPresentation: Equatable, Sendable {
  static let empty = Self(
    filteredItems: [],
    groupedItems: [],
    relativeUpdatedLabels: [:]
  )

  let filteredItems: [DependencyUpdateItem]
  let groupedItems: [DashboardDependenciesRepositoryGroup]
  let relativeUpdatedLabels: [String: String]
}

struct DashboardDependenciesPresentation: Equatable, Sendable {
  static let empty = Self(
    filteredItems: [],
    groupedItems: [],
    selectedItems: [],
    primaryDetailItem: nil,
    relativeUpdatedLabels: [:]
  )

  let filteredItems: [DependencyUpdateItem]
  let groupedItems: [DashboardDependenciesRepositoryGroup]
  let selectedItems: [DependencyUpdateItem]
  let primaryDetailItem: DependencyUpdateItem?
  let relativeUpdatedLabels: [String: String]
}

actor DashboardDependenciesPresentationWorker {
  private static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf"
  )

  private var cachedListInput: DashboardDependenciesListPresentationInput?
  private var cachedListPresentation = DashboardDependenciesListPresentation.empty

  func compute(
    input: DashboardDependenciesPresentationInput
  ) -> DashboardDependenciesPresentation {
    let listInput = DashboardDependenciesListPresentationInput(input)
    let listPresentation = computeListPresentation(input: listInput)
    let sortMode = DashboardDependenciesSortMode(rawValue: input.sortModeRaw) ?? .status
    let comparator = sortMode.comparator
    let selectedItems = input.items
      .filter { input.selectedIDs.contains($0.pullRequestID) }
      .sorted(by: comparator)
    return DashboardDependenciesPresentation(
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
    input: DashboardDependenciesListPresentationInput
  ) -> DashboardDependenciesListPresentation {
    guard input != cachedListInput else {
      return cachedListPresentation
    }
    let signpostID = Self.signposter.makeSignpostID()
    let interval = Self.signposter.beginInterval(
      "dashboard_dependencies.presentation.compute",
      id: signpostID,
      "items=\(input.items.count, privacy: .public)"
    )
    defer {
      Self.signposter.endInterval(
        "dashboard_dependencies.presentation.compute",
        interval,
        "visible=\(self.cachedListPresentation.filteredItems.count, privacy: .public)"
      )
    }
    cachedListInput = input
    cachedListPresentation = Self.listPresentation(from: input)
    return cachedListPresentation
  }

  private static func listPresentation(
    from input: DashboardDependenciesListPresentationInput
  ) -> DashboardDependenciesListPresentation {
    let filterMode = DashboardDependenciesFilterMode(rawValue: input.filterModeRaw) ?? .all
    let sortMode = DashboardDependenciesSortMode(rawValue: input.sortModeRaw) ?? .status
    let comparator = sortMode.comparator
    let query = input.searchText.trimmingCharacters(in: .whitespacesAndNewlines)

    let filteredItems = input.items
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
    return DashboardDependenciesListPresentation(
      filteredItems: filteredItems,
      groupedItems: groupedItems,
      relativeUpdatedLabels: relativeUpdatedLabels(for: filteredItems)
    )
  }

  private static func relativeUpdatedLabels(
    for items: [DependencyUpdateItem],
    relativeTo now: Date = .now
  ) -> [String: String] {
    let formatter = ISO8601DateFormatter()
    let relativeFormatter = RelativeDateTimeFormatter()
    relativeFormatter.unitsStyle = .short
    return Dictionary(
      items.map { item -> (String, String) in
        guard let date = formatter.date(from: item.updatedAt) else {
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
    _ filteredItems: [DependencyUpdateItem],
    sort comparator: (DependencyUpdateItem, DependencyUpdateItem) -> Bool,
    configuredRepositories: [String],
    configuredOrganizations: [String]
  ) -> [DashboardDependenciesRepositoryGroup] {
    let grouped = Dictionary(grouping: filteredItems, by: \.repository)
    let ordering = DashboardDependenciesRepositoryOrdering(
      configuredRepositories: configuredRepositories,
      configuredOrganizations: configuredOrganizations
    )
    return
      grouped
      .map { repository, items in
        DashboardDependenciesRepositoryGroup(
          repository: repository,
          items: items.sorted(by: comparator)
        )
      }
      .sorted { ordering.compare($0.repository, $1.repository) }
  }

  private static func primaryDetailItem(
    selectedItems: [DependencyUpdateItem],
    filteredItems: [DependencyUpdateItem],
    persistedPrimarySelectionID: String
  ) -> DependencyUpdateItem? {
    if selectedItems.count == 1 {
      return selectedItems.first
    }
    if selectedItems.isEmpty, !persistedPrimarySelectionID.isEmpty {
      return filteredItems.first { $0.pullRequestID == persistedPrimarySelectionID }
    }
    return selectedItems.isEmpty ? filteredItems.first : nil
  }
}
