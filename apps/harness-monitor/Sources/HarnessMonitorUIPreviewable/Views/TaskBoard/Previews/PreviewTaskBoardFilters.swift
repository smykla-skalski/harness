import HarnessMonitorKit
import SwiftUI

#Preview("Task Board Filter Bar") {
  TaskBoardFilterBarPreview(filters: TaskBoardFilterPreviewFixtures.narrowedFilters)
    .padding(24)
    .frame(width: 900)
}

#Preview("Task Board Filter Popover") {
  TaskBoardFilterPopoverPreview(filters: TaskBoardFilterPreviewFixtures.narrowedFilters)
    .frame(width: 420, height: 420)
}

#Preview("Task Board Project Filter") {
  TaskBoardFacetFilterOptionsPreview(
    facet: .project,
    filters: TaskBoardFilterPreviewFixtures.narrowedFilters
  )
}

#Preview("Task Board Priority Filter") {
  TaskBoardFacetFilterOptionsPreview(
    facet: .priority,
    filters: TaskBoardFilterPreviewFixtures.narrowedFilters
  )
}

#Preview("Task Board Filter Empty State") {
  TaskBoardFilterEmptyStatePreview()
    .padding(24)
    .frame(width: 640)
}

/// The row the board carries above its lanes: what is left, the search, the
/// facets, and a way to drop any one value.
struct TaskBoardFilterBarPreview: View {
  @State private var filters: TaskBoardFilterState
  @State private var searchText: String

  init(filters: TaskBoardFilterState, searchText: String = "") {
    _filters = State(initialValue: filters)
    _searchText = State(initialValue: searchText)
  }

  var body: some View {
    let inventory = TaskBoardFilterPreviewFixtures.inventory(for: filters, search: searchText)
    return VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingMD) {
        TaskBoardSummaryPill(
          value: "\(TaskBoardFilterPreviewFixtures.matchCount(for: filters, search: searchText))",
          label: "Open",
          systemImage: "rectangle.stack",
          tint: HarnessMonitorTheme.secondaryInk
        )
        Spacer(minLength: HarnessMonitorTheme.spacingMD)
        TaskBoardSearchField(
          text: $searchText,
          candidates: TaskBoardFilterPreviewFixtures.searchCandidates(for: filters)
        )
        TaskBoardFilterControls(filters: $filters, inventory: inventory)
          .fixedSize(horizontal: true, vertical: false)
      }
      let chips = inventory.activeChips(for: filters)
      if !chips.isEmpty {
        TaskBoardActiveFilterChips(filters: $filters, chips: chips)
      }
    }
  }
}

/// The facets behind the general control, each value carrying what it would
/// leave.
struct TaskBoardFilterPopoverPreview: View {
  @State private var filters: TaskBoardFilterState

  init(filters: TaskBoardFilterState) {
    _filters = State(initialValue: filters)
  }

  var body: some View {
    TaskBoardFilterPopover(
      filters: $filters,
      inventory: TaskBoardFilterPreviewFixtures.inventory(for: filters)
    )
  }
}

/// One facet's values, as they hang under that facet's own button.
struct TaskBoardFacetFilterOptionsPreview: View {
  let facet: TaskBoardFilterFacet
  @State private var filters: TaskBoardFilterState

  init(facet: TaskBoardFilterFacet, filters: TaskBoardFilterState) {
    self.facet = facet
    _filters = State(initialValue: filters)
  }

  var body: some View {
    TaskBoardFacetFilterOptions(
      facet: facet,
      filters: $filters,
      options: TaskBoardFilterPreviewFixtures.inventory(for: filters).options(for: facet)
    )
  }
}

/// A board its own filter or search has emptied, naming what is responsible.
struct TaskBoardFilterEmptyStatePreview: View {
  @State private var filters: TaskBoardFilterState
  @State private var searchText: String

  init(
    filters: TaskBoardFilterState = TaskBoardFilterPreviewFixtures.emptyingFilters,
    searchText: String = ""
  ) {
    _filters = State(initialValue: filters)
    _searchText = State(initialValue: searchText)
  }

  var body: some View {
    TaskBoardFilteredEmptyStateView(
      filters: $filters,
      searchText: $searchText,
      responsibleCauses: TaskBoardFilterPreviewFixtures.responsibleCauses(
        for: filters,
        search: searchText
      )
    )
    .frame(maxWidth: .infinity, minHeight: 180)
    .background(
      .background.opacity(0.45), in: .rect(cornerRadius: HarnessMonitorTheme.cornerRadiusSM))
  }
}

/// A small board spread across every facet, run through the same reducer the
/// real board uses so the counts on screen are the counts the code produces.
enum TaskBoardFilterPreviewFixtures {
  static var narrowedFilters: TaskBoardFilterState {
    var filters = TaskBoardFilterState()
    filters.toggleProject("project-kuma")
    filters.togglePriority(.critical)
    filters.togglePriority(.high)
    filters.toggleTag("backend")
    return filters
  }

  /// On its own it leaves plenty; with a search for `zone` it leaves nothing,
  /// which is the case where both are named.
  static var searchEmptyingFilters: TaskBoardFilterState {
    var filters = TaskBoardFilterState()
    filters.toggleProject("project-harness")
    return filters
  }

  static var emptyingFilters: TaskBoardFilterState {
    var filters = TaskBoardFilterState()
    filters.togglePriority(.critical)
    filters.toggleProject("project-harness")
    filters.toggleTag("monitor")
    return filters
  }

  static func inventory(
    for filters: TaskBoardFilterState,
    search: String = ""
  ) -> TaskBoardFilterInventory {
    board(for: filters, search: search).inventory
  }

  static func matchCount(for filters: TaskBoardFilterState, search: String = "") -> Int {
    board(for: filters, search: search).items.count
  }

  static func responsibleCauses(
    for filters: TaskBoardFilterState,
    search: String = ""
  ) -> [TaskBoardNarrowingCause] {
    board(for: filters, search: search).responsibleCauses
  }

  static func searchCandidates(for filters: TaskBoardFilterState) -> [TaskBoardSearchCandidate] {
    board(for: filters).searchCandidates
  }

  /// The rows the real index produces, so a snapshot never shows a suggestion
  /// the engine would not.
  static func suggestions(
    query: String,
    for filters: TaskBoardFilterState = TaskBoardFilterState()
  ) -> [TaskBoardSearchSuggestion] {
    guard
      let index = try? TaskBoardSearchSuggestionIndex(candidates: searchCandidates(for: filters))
    else {
      return []
    }
    return index.suggestions(query: query)
  }

  static func board(
    for filters: TaskBoardFilterState,
    search: String = ""
  ) -> TaskBoardFilteredBoard {
    TaskBoardFilteredBoard(
      scopedItems: items,
      visibleItems: items,
      inboxItems: [],
      decisions: [],
      projectLabelResolver: TaskBoardProjectLabelResolver(
        projects: projects,
        projectIDs: items.compactMap(\.taskBoardRepositoryIdentity)
      ),
      filters: filters,
      search: TaskBoardSearchQuery(search)
    )
  }

  private static let projects = [
    TaskBoardProjectSummary(
      projectId: "project-kuma",
      source: .gitHub,
      slug: "kumahq/kuma",
      displayName: "Kuma Mesh",
      color: .teal,
      itemCount: 3,
      readyCount: 2
    ),
    TaskBoardProjectSummary(
      projectId: "project-harness",
      source: .gitHub,
      slug: "smykla-skalski/harness",
      displayName: "Harness",
      color: .purple,
      itemCount: 3,
      readyCount: 1
    ),
  ]

  private static let items: [TaskBoardItem] = [
    item(
      id: "kuma-mesh-policy",
      title: "Split the mesh policy reconciler",
      status: .todo,
      priority: .high,
      tags: ["backend", "mesh"],
      projectSlug: "kumahq/kuma",
      projectID: "project-kuma"
    ),
    item(
      id: "kuma-zone-sync",
      title: "Retry zone sync on partial failure",
      status: .inProgress,
      priority: .critical,
      tags: ["backend"],
      projectSlug: "kumahq/kuma",
      projectID: "project-kuma",
      importedFromProvider: .gitHub
    ),
    item(
      id: "kuma-docs",
      title: "Document the policy merge order",
      // Carries `zone` only in the body, so a search reaching it proves the
      // board reads more than the titles it shows.
      body: "Explain how a zone inherits a mesh policy and where the order breaks.",
      status: .toReview,
      priority: .low,
      tags: ["docs"],
      projectSlug: "kumahq/kuma",
      projectID: "project-kuma"
    ),
    item(
      id: "harness-board-filter",
      title: "Filter the task board by field",
      status: .todo,
      priority: .medium,
      tags: ["monitor", "backend"],
      projectSlug: "smykla-skalski/harness",
      projectID: "project-harness",
      importedFromProvider: .gitHub
    ),
    item(
      id: "harness-lane-colours",
      title: "Give each lane its own colour",
      status: .inReview,
      priority: .low,
      tags: ["monitor", "ui"],
      projectSlug: "smykla-skalski/harness",
      projectID: "project-harness"
    ),
    item(
      id: "harness-pairing",
      title: "Pairing panel drops the device on re-pair",
      status: .humanRequired,
      priority: .critical,
      tags: ["ui"],
      projectSlug: "smykla-skalski/harness",
      projectID: "project-harness",
      importedFromProvider: .gitHub
    ),
    item(
      id: "site-deploy",
      title: "Deploy the static site behind the tunnel",
      status: .failed,
      priority: .medium,
      tags: ["infra"],
      projectSlug: "example/site"
    ),
  ]

  private static func item(
    id: String,
    title: String,
    body: String = "",
    status: TaskBoardStatus,
    priority: TaskBoardPriority,
    tags: [String],
    projectSlug: String,
    projectID: String? = nil,
    importedFromProvider: TaskBoardExternalRefProvider? = nil
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: title,
      body: body,
      status: status,
      priority: priority,
      tags: tags,
      projectId: projectSlug,
      sourceProjectId: projectID,
      agentMode: .headless,
      externalRefs: [],
      importedFromProvider: importedFromProvider,
      planning: TaskBoardPlanningState(),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      createdAt: "2026-07-27T09:00:00Z",
      updatedAt: "2026-07-27T10:00:00Z",
      deletedAt: nil
    )
  }
}
