import HarnessMonitorKit
import SwiftUI

#Preview("Task Board Search Field") {
  TaskBoardSearchFieldPreview(searchText: "")
    .padding(24)
    .frame(width: 420, height: 120)
}

#Preview("Task Board Search Suggestions") {
  // Misspelt on purpose: the rows under a typo are the whole point of them
  // being fuzzy while the board behind them is not.
  TaskBoardSearchFieldPreview(searchText: "polcy", showsSuggestions: true)
    .padding(24)
    .frame(width: 420, height: 260)
}

#Preview("Task Board Search And Filters") {
  TaskBoardFilterBarPreview(
    filters: TaskBoardFilterPreviewFixtures.narrowedFilters,
    searchText: "policy"
  )
  .padding(24)
  .frame(width: 980)
}

#Preview("Task Board Search Empty State") {
  TaskBoardFilterEmptyStatePreview(filters: TaskBoardFilterState(), searchText: "nothing here")
    .padding(24)
    .frame(width: 640)
}

/// The field on its own, with the suggestions it hangs underneath.
struct TaskBoardSearchFieldPreview: View {
  @State private var searchText: String
  private let showsSuggestions: Bool

  init(searchText: String, showsSuggestions: Bool = false) {
    _searchText = State(initialValue: searchText)
    self.showsSuggestions = showsSuggestions
  }

  var body: some View {
    TaskBoardSearchField(
      text: $searchText,
      candidates: TaskBoardFilterPreviewFixtures.searchCandidates(
        for: TaskBoardFilterState()
      ),
      pinnedSuggestions: showsSuggestions
        ? TaskBoardFilterPreviewFixtures.suggestions(query: searchText)
        : []
    )
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
