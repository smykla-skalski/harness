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

/// The filter bar as the board carries it: how many values are on, the values
/// themselves, and a way to drop any one of them.
struct TaskBoardFilterBarPreview: View {
  @State private var filters: TaskBoardFilterState

  init(filters: TaskBoardFilterState) {
    _filters = State(initialValue: filters)
  }

  var body: some View {
    let inventory = TaskBoardFilterPreviewFixtures.inventory(for: filters)
    return VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingMD) {
        TaskBoardSummaryPill(
          value: "\(TaskBoardFilterPreviewFixtures.matchCount(for: filters))",
          label: "Open",
          systemImage: "rectangle.stack",
          tint: HarnessMonitorTheme.secondaryInk
        )
        Spacer(minLength: HarnessMonitorTheme.spacingMD)
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

/// A board its own filter has emptied, naming the filter responsible.
struct TaskBoardFilterEmptyStatePreview: View {
  @State private var filters = TaskBoardFilterPreviewFixtures.emptyingFilters

  var body: some View {
    TaskBoardFilteredEmptyStateView(
      filters: $filters,
      responsibleFacets: TaskBoardFilterPreviewFixtures.responsibleFacets(for: filters)
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

  static var emptyingFilters: TaskBoardFilterState {
    var filters = TaskBoardFilterState()
    filters.togglePriority(.critical)
    filters.toggleProject("project-harness")
    filters.toggleTag("monitor")
    return filters
  }

  static func inventory(for filters: TaskBoardFilterState) -> TaskBoardFilterInventory {
    board(for: filters).inventory
  }

  static func matchCount(for filters: TaskBoardFilterState) -> Int {
    board(for: filters).items.count
  }

  static func responsibleFacets(for filters: TaskBoardFilterState) -> [TaskBoardFilterFacet] {
    board(for: filters).responsibleFacets
  }

  private static func board(for filters: TaskBoardFilterState) -> TaskBoardFilteredBoard {
    TaskBoardFilteredBoard(
      scopedItems: items,
      visibleItems: items,
      inboxItems: [],
      decisionIDs: [],
      projectLabelResolver: TaskBoardProjectLabelResolver(
        projects: projects,
        projectIDs: items.compactMap(\.taskBoardRepositoryIdentity)
      ),
      filters: filters
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
      body: "",
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
