import Foundation
import HarnessMonitorKit

/// The one view of a card a board filter is allowed to read.
///
/// Every card on the board reduces to this before matching, so a live session
/// task and a board item are narrowed by the same rules instead of each lane
/// growing its own. A field left `nil` is a field the card does not carry, and
/// a filter on that field never selects the card.
struct TaskBoardFilterFields: Equatable, Sendable {
  var priority: TaskBoardPriority?
  var projectKey: String?
  var projectLabel: String?
  /// Original spellings; matching canonicalizes them.
  var tags: [String] = []
  var source: TaskBoardFilterSource?

  /// An open decision carries none of the fields a filter reads, so any active
  /// filter excludes it.
  static let decision = Self()

  init(
    priority: TaskBoardPriority? = nil,
    projectKey: String? = nil,
    projectLabel: String? = nil,
    tags: [String] = [],
    source: TaskBoardFilterSource? = nil
  ) {
    self.priority = priority
    self.projectKey = projectKey
    self.projectLabel = projectLabel
    self.tags = tags
    self.source = source
  }
}

extension TaskBoardFilterFields {
  init(item: TaskBoardItem, projectLabelResolver: TaskBoardProjectLabelResolver) {
    self.init(
      priority: item.priority,
      projectKey: Self.projectKey(for: item),
      projectLabel: projectLabelResolver.label(for: item, alwaysShowFullName: true),
      tags: item.tags,
      source: item.importedFromProvider == .gitHub ? .gitHub : .harness
    )
  }

  init(inboxItem: TaskBoardInboxItem) {
    self.init(priority: Self.priority(for: inboxItem.task.severity))
  }

  /// The identity a project filter selects on: the registered project when the
  /// item names one, else the repository the item carries. Keyed on the stored
  /// identity rather than the label so renaming a project keeps its filter.
  static func projectKey(for item: TaskBoardItem) -> String? {
    if let sourceProjectID = item.sourceProjectId, !sourceProjectID.isEmpty {
      return sourceProjectID
    }
    return item.taskBoardRepositoryIdentity
  }

  private static func priority(for severity: TaskSeverity) -> TaskBoardPriority {
    switch severity {
    case .low:
      .low
    case .medium:
      .medium
    case .high:
      .high
    case .critical:
      .critical
    }
  }
}

/// One filter selection reduced for scanning a board.
struct TaskBoardFilterMatcher: Sendable {
  let filters: TaskBoardFilterState

  var isEmpty: Bool { filters.isEmpty }

  /// Whether `fields` survives the filter. `excluding` drops one facet from the
  /// test, which is how a facet counts what it would leave without counting its
  /// own selection.
  func matches(
    _ fields: TaskBoardFilterFields,
    excluding excludedFacet: TaskBoardFilterFacet? = nil
  ) -> Bool {
    TaskBoardFilterFacet.allCases.allSatisfy { facet in
      facet == excludedFacet || matches(fields, facet: facet)
    }
  }

  private func matches(_ fields: TaskBoardFilterFields, facet: TaskBoardFilterFacet) -> Bool {
    switch facet {
    case .project:
      filters.projects.isEmpty || fields.projectKey.map(filters.projects.contains) ?? false
    case .priority:
      filters.priorities.isEmpty || fields.priority.map(filters.priorities.contains) ?? false
    case .tag:
      filters.tags.isEmpty
        || fields.tags.contains { filters.tags.contains(TaskBoardFilterState.tagKey($0)) }
    case .source:
      filters.sources.isEmpty || fields.source.map(filters.sources.contains) ?? false
    }
  }

  /// The facets to blame when the filter leaves nothing.
  ///
  /// A facet is named when dropping it alone brings items back. When no single
  /// facet does, only the combination is at fault, so every active one is named
  /// rather than pointing at an innocent single filter.
  static func responsibleFacets(
    in population: [TaskBoardFilterFields],
    matcher: TaskBoardFilterMatcher
  ) -> [TaskBoardFilterFacet] {
    let activeFacets = matcher.filters.activeFacets
    guard !activeFacets.isEmpty else {
      return []
    }
    let individuallyResponsible = activeFacets.filter { facet in
      population.contains { matcher.matches($0, excluding: facet) }
    }
    return individuallyResponsible.isEmpty ? activeFacets : individuallyResponsible
  }
}
