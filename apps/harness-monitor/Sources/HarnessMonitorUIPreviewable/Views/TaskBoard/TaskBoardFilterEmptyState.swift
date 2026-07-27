import SwiftUI

/// What to tell someone whose own filter or search has hidden the whole board.
enum TaskBoardFilterEmptyState {
  static func description(responsibleCauses: [TaskBoardNarrowingCause]) -> String {
    guard !responsibleCauses.isEmpty else {
      return "Nothing on the board matches."
    }
    let subject = list(phrases(for: responsibleCauses))
    guard responsibleCauses.count > 1 else {
      return "Nothing on the board matches \(subject)."
    }
    return "Nothing on the board matches \(subject) together."
  }

  /// Names exactly what the button is about to switch off, so it never offers
  /// to clear a filter the message did not blame.
  static func clearTitle(responsibleCauses: [TaskBoardNarrowingCause]) -> String {
    let clearsSearch = responsibleCauses.contains(.search)
    let facetCount = responsibleCauses.count - (clearsSearch ? 1 : 0)
    switch (clearsSearch, facetCount) {
    case (true, 0):
      return "Clear Search"
    case (true, _):
      return "Clear Search and Filters"
    case (false, 1):
      return "Clear Filter"
    default:
      return "Clear Filters"
    }
  }

  /// The glyph names the control to go back to.
  static func systemImage(responsibleCauses: [TaskBoardNarrowingCause]) -> String {
    responsibleCauses == [.search]
      ? "magnifyingglass"
      : "line.3.horizontal.decrease.circle"
  }

  /// The search reads as itself; a facet reads as the field it narrows.
  ///
  /// Several facets normally share one phrase, which reads better than spelling
  /// each out. The exception is a search standing beside them: "the search and
  /// the project and priority filters" buries one "and" inside another, so
  /// there the facets go back to a phrase each and the commas do the joining.
  private static func phrases(for causes: [TaskBoardNarrowingCause]) -> [String] {
    let hasSearch = causes.contains(.search)
    let facetNames = causes.compactMap { cause -> String? in
      guard case .facet(let facet) = cause else { return nil }
      return facet.title.lowercased()
    }

    var phrases: [String] = hasSearch ? ["the search"] : []
    guard !facetNames.isEmpty else {
      return phrases
    }
    if hasSearch && facetNames.count > 1 {
      phrases.append(contentsOf: facetNames.map { "the \($0) filter" })
    } else {
      phrases.append("the \(list(facetNames)) \(facetNames.count == 1 ? "filter" : "filters")")
    }
    return phrases
  }

  private static func list(_ names: [String]) -> String {
    guard let last = names.last else {
      return ""
    }
    guard names.count > 1 else {
      return last
    }
    return names.dropLast().joined(separator: ", ") + " and " + last
  }
}

/// A board hidden by its own filter or search says which one did it, so nobody
/// reads a narrowed board as an empty one.
struct TaskBoardFilteredEmptyStateView: View {
  @Binding var filters: TaskBoardFilterState
  @Binding var searchText: String
  let responsibleCauses: [TaskBoardNarrowingCause]

  var body: some View {
    ContentUnavailableView {
      Label(
        "No Matching Items",
        systemImage: TaskBoardFilterEmptyState.systemImage(responsibleCauses: responsibleCauses)
      )
    } description: {
      Text(TaskBoardFilterEmptyState.description(responsibleCauses: responsibleCauses))
    } actions: {
      Button(TaskBoardFilterEmptyState.clearTitle(responsibleCauses: responsibleCauses)) {
        clearResponsibleCauses()
      }
      .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
      .harnessNativeFormControl()
      .accessibilityIdentifier("harness.task-board.filters.empty-state.clear")
    }
    .accessibilityIdentifier("harness.task-board.filters.empty-state")
  }

  private func clearResponsibleCauses() {
    var remaining = filters
    var clearsSearch = false
    for cause in responsibleCauses {
      switch cause {
      case .search:
        clearsSearch = true
      case .facet(let facet):
        remaining.clear(facet)
      }
    }
    if remaining != filters {
      filters = remaining
    }
    if clearsSearch {
      searchText = ""
    }
  }
}
