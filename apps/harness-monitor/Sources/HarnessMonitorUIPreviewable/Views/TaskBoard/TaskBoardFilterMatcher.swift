import Foundation
import HarnessMonitorKit

/// One thing that is currently narrowing the board.
///
/// The search and the facets narrow the same way and are equally able to empty
/// the board, so an empty board has to be able to point at either.
enum TaskBoardNarrowingCause: Equatable, Sendable, Identifiable {
  case search
  case facet(TaskBoardFilterFacet)

  var id: String {
    switch self {
    case .search:
      "search"
    case .facet(let facet):
      facet.rawValue
    }
  }
}

/// The current filter and search, reduced for scanning a board.
struct TaskBoardFilterMatcher: Sendable {
  let filters: TaskBoardFilterState
  let search: TaskBoardSearchQuery

  init(filters: TaskBoardFilterState, search: TaskBoardSearchQuery = .none) {
    self.filters = filters
    self.search = search
  }

  var isEmpty: Bool { filters.isEmpty && search.isEmpty }

  /// Everything narrowing the board right now, search first because that is how
  /// the empty state reads it back.
  var activeCauses: [TaskBoardNarrowingCause] {
    (search.isEmpty ? [] : [.search]) + filters.activeFacets.map(TaskBoardNarrowingCause.facet)
  }

  /// Whether `fields` survives. `excluding` drops one cause from the test, which
  /// is how a facet counts what it would leave without counting its own
  /// selection, and how an empty board finds out which cause emptied it.
  func matches(
    _ fields: TaskBoardFilterFields,
    excluding excludedCause: TaskBoardNarrowingCause? = nil
  ) -> Bool {
    if excludedCause != .search, !search.matches(fields) {
      return false
    }
    return TaskBoardFilterFacet.allCases.allSatisfy { facet in
      excludedCause == .facet(facet) || matches(fields, facet: facet)
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

  /// What to blame when nothing is left.
  ///
  /// A cause is named when dropping it alone brings items back. When no single
  /// one does, only the combination is at fault, so every active cause is named
  /// rather than pointing at an innocent one.
  static func responsibleCauses(
    in population: [TaskBoardFilterFields],
    matcher: Self
  ) -> [TaskBoardNarrowingCause] {
    let activeCauses = matcher.activeCauses
    guard !activeCauses.isEmpty else {
      return []
    }
    let individuallyResponsible = activeCauses.filter { cause in
      population.contains { matcher.matches($0, excluding: cause) }
    }
    return individuallyResponsible.isEmpty ? activeCauses : individuallyResponsible
  }
}
