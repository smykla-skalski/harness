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

struct DashboardDependenciesPresentation: Equatable, Sendable {
  static let empty = Self(
    filteredItems: [],
    groupedItems: [],
    selectedItems: [],
    primaryDetailItem: nil
  )

  let filteredItems: [DependencyUpdateItem]
  let groupedItems: [DashboardDependenciesRepositoryGroup]
  let selectedItems: [DependencyUpdateItem]
  let primaryDetailItem: DependencyUpdateItem?
}

actor DashboardDependenciesPresentationWorker {
  private static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf"
  )

  private var cachedInput: DashboardDependenciesPresentationInput?
  private var cachedOutput = DashboardDependenciesPresentation.empty

  func compute(
    input: DashboardDependenciesPresentationInput
  ) -> DashboardDependenciesPresentation {
    guard input != cachedInput else {
      return cachedOutput
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
        "visible=\(self.cachedOutput.filteredItems.count, privacy: .public)"
      )
    }

    cachedInput = input
    cachedOutput = Self.presentation(from: input)
    return cachedOutput
  }

  func waitForIdle() async {}

  private static func presentation(
    from input: DashboardDependenciesPresentationInput
  ) -> DashboardDependenciesPresentation {
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
    let selectedItems = input.items
      .filter { input.selectedIDs.contains($0.pullRequestID) }
      .sorted(by: comparator)

    return DashboardDependenciesPresentation(
      filteredItems: filteredItems,
      groupedItems: groupedItems,
      selectedItems: selectedItems,
      primaryDetailItem: primaryDetailItem(
        selectedItems: selectedItems,
        filteredItems: filteredItems,
        persistedPrimarySelectionID: input.persistedPrimarySelectionID
      )
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
