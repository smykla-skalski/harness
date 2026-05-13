import HarnessMonitorKit
import SwiftUI

/// Sectioned popover content rendered inside `.searchSuggestions { … }`.
///
/// Rows are native search completions, not custom controls. Selection
/// replaces the search text with the row's completion and triggers the
/// host's `.onSubmit(of: .search)` routing path.
public struct AppSearchSuggestionsView: View {
  let snapshot: AppSearchSuggestionSnapshot

  public init(snapshot: AppSearchSuggestionSnapshot) {
    self.snapshot = snapshot
  }

  public var body: some View {
    ForEach(snapshot.rows) { row in
      Text(verbatim: row.displayTitle)
        .searchCompletion(row.completion)
    }
  }
}
