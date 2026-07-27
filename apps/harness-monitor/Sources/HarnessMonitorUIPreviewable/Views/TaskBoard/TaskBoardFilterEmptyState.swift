import SwiftUI

/// What to tell someone whose filter has hidden the whole board.
enum TaskBoardFilterEmptyState {
  static func description(responsibleFacets: [TaskBoardFilterFacet]) -> String {
    guard !responsibleFacets.isEmpty else {
      return "Nothing on the board matches the filter."
    }
    let names = list(responsibleFacets.map { $0.title.lowercased() })
    if responsibleFacets.count == 1 {
      return "Nothing on the board matches the \(names) filter."
    }
    return "Nothing on the board matches the \(names) filters together."
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

/// A board hidden by its own filter says which filter did it, so nobody reads
/// a narrowed board as an empty one.
struct TaskBoardFilteredEmptyStateView: View {
  @Binding var filters: TaskBoardFilterState
  let responsibleFacets: [TaskBoardFilterFacet]

  var body: some View {
    ContentUnavailableView {
      Label("No Matching Items", systemImage: "line.3.horizontal.decrease.circle")
    } description: {
      Text(TaskBoardFilterEmptyState.description(responsibleFacets: responsibleFacets))
    } actions: {
      Button("Clear Filter") {
        filters.clear()
      }
      .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
      .harnessNativeFormControl()
      .accessibilityIdentifier("harness.task-board.filters.empty-state.clear")
    }
    .accessibilityIdentifier("harness.task-board.filters.empty-state")
  }
}
