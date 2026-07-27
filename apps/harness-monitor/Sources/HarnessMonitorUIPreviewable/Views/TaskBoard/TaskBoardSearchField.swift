import HarnessMonitorKit
import SwiftUI

/// The board's search: literal narrowing behind the field, fuzzy suggestions
/// under it. The two are deliberately different - the suggestions are there to
/// survive a typo, the board is there to be explainable from what was typed.
struct TaskBoardSearchField: View {
  @Binding var text: String
  let candidates: [TaskBoardSearchCandidate]
  /// Previews and shell snapshots render without a key window to take focus and
  /// without a chance to await the worker, so they hand the rows in directly.
  var pinnedSuggestions: [TaskBoardSearchSuggestion] = []

  @Environment(\.fontScale)
  private var fontScale
  @FocusState private var isFocused: Bool
  @State private var suggestionWorker = TaskBoardSearchSuggestionWorker()
  @State private var suggestions: [TaskBoardSearchSuggestion] = []
  /// The text the suggestion list was last dismissed at. Typing moves the text
  /// off it and brings the list back.
  @State private var suppressedText: String?
  @State private var fieldSize: CGSize = .zero

  var body: some View {
    // Read once, so the task's identity and the snapshot it runs against are
    // the same value rather than two reads of state that can move between them.
    let request = suggestionRequest
    return field
      .frame(
        minWidth: 150 * controlScale,
        idealWidth: 220 * controlScale,
        maxWidth: 300 * controlScale
      )
      .onGeometryChange(for: CGSize.self) { proxy in
        proxy.size
      } action: { size in
        if fieldSize != size {
          fieldSize = size
        }
      }
      .overlay(alignment: .topLeading) {
        suggestionList
      }
      .task(id: request) {
        await refreshSuggestions(for: request)
      }
      .onExitCommand {
        suppressedText = text
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("harness.task-board.search")
  }

  private var field: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .accessibilityHidden(true)
      TextField("Search the board", text: $text)
        .textFieldStyle(.plain)
        .focused($isFocused)
        .onSubmit {
          suppressedText = text
          isFocused = false
        }
        .accessibilityLabel("Search the board by title, body, or tag")
        .accessibilityIdentifier("harness.task-board.search.field")
      if !text.isEmpty {
        Button {
          text = ""
          suppressedText = nil
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
        .buttonStyle(.borderless)
        .help("Clear the search")
        .accessibilityLabel("Clear the search")
        .accessibilityIdentifier("harness.task-board.search.clear")
      }
    }
    .scaledFont(.caption)
    .padding(.horizontal, HarnessMonitorTheme.spacingSM)
    .padding(.vertical, HarnessMonitorTheme.spacingXS + 1)
    .background(
      HarnessMonitorTheme.ink.opacity(0.10),
      in: .rect(cornerRadius: HarnessMonitorTheme.cornerRadiusSM)
    )
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM)
        .strokeBorder(
          isFocused ? HarnessMonitorTheme.accent : HarnessMonitorTheme.controlBorder,
          lineWidth: 1
        )
    }
  }

  @ViewBuilder private var suggestionList: some View {
    if showsSuggestions {
      TaskBoardSearchSuggestionList(
        suggestions: visibleSuggestions,
        width: max(fieldSize.width, 300 * controlScale),
        text: $text,
        suppressedText: $suppressedText
      )
      // Hangs below the field instead of pushing the board down: the row it
      // sits in is chrome, and reflowing the lanes on every keystroke would
      // move the very cards someone is reading. An offset rather than a bottom
      // alignment, because an overlay taller than its host grows upwards.
      .fixedSize()
      .offset(y: fieldSize.height + HarnessMonitorTheme.spacingXS)
    }
  }

  private var showsSuggestions: Bool {
    isSuggesting && !visibleSuggestions.isEmpty && text != suppressedText
  }

  private var visibleSuggestions: [TaskBoardSearchSuggestion] {
    pinnedSuggestions.isEmpty ? suggestions : pinnedSuggestions
  }

  private var isSuggesting: Bool {
    isFocused || !pinnedSuggestions.isEmpty
  }

  private var controlScale: CGFloat {
    max(1, min(fontScale, 1.4))
  }

  /// Carries the whole candidate set rather than a count of it. Switching a
  /// facet can leave a different set of the same size, and a key that cannot
  /// see that difference leaves the rows under the field describing the board
  /// someone was looking at a moment ago.
  private struct SuggestionRequest: Equatable {
    let query: String
    let isSuggesting: Bool
    let candidates: [TaskBoardSearchCandidate]
  }

  private var suggestionRequest: SuggestionRequest {
    SuggestionRequest(
      query: text,
      isSuggesting: isSuggesting,
      candidates: candidates
    )
  }

  @MainActor
  private func refreshSuggestions(for request: SuggestionRequest) async {
    guard
      request.isSuggesting,
      pinnedSuggestions.isEmpty,
      !HarnessMonitorPerfIsolation.disablesSearchSuggestions
    else {
      if !suggestions.isEmpty {
        suggestions = []
      }
      return
    }
    // The request's own candidates, not the view's: indexing a set this result
    // is about to be discarded for is work nobody asked for.
    let matches = await suggestionWorker.suggestions(
      query: request.query,
      candidates: request.candidates
    )
    guard !Task.isCancelled, request == suggestionRequest else {
      return
    }
    suggestions = matches
  }
}

/// The rows under the field, each one a card someone can point at.
///
/// Takes the text it writes rather than a closure to call: a closure stored on a
/// view struct is the one thing SwiftUI cannot compare, so it would rebuild
/// these rows on every pass the field makes.
private struct TaskBoardSearchSuggestionList: View {
  private static let rowInset = HarnessMonitorTheme.spacingXS
  private static let rowCornerRadius = HarnessMonitorTheme.cornerRadiusSM - rowInset

  let suggestions: [TaskBoardSearchSuggestion]
  let width: CGFloat
  @Binding var text: String
  @Binding var suppressedText: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(suggestions) { suggestion in
        Button {
          text = suggestion.title
          // Picking a row is an answer, so the list closes rather than
          // suggesting against the title it just filled in.
          suppressedText = suggestion.title
        } label: {
          TaskBoardSearchSuggestionRow(suggestion: suggestion)
        }
        .harnessInteractiveCardButtonStyle(cornerRadius: Self.rowCornerRadius)
        .accessibilityLabel("Search for \(suggestion.title)")
        // Two cards can carry the same title in different projects, and the
        // subtitle is the only thing telling them apart on screen.
        .accessibilityValue(suggestion.subtitle)
        .accessibilityHint("Fills the search field with this title")
      }
    }
    // Inset by the difference between the two radii, so a row's highlight sits
    // concentric inside the container's curve instead of squaring off over it.
    .padding(Self.rowInset)
    .frame(width: width, alignment: .leading)
    .background(
      .regularMaterial,
      in: .rect(cornerRadius: HarnessMonitorTheme.cornerRadiusSM)
    )
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM)
        .strokeBorder(HarnessMonitorTheme.controlBorder, lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.28), radius: 12, y: 6)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.search.suggestions")
  }
}

/// Presentation only: hover, press, and the hit region belong to the button
/// style the row is mounted in.
private struct TaskBoardSearchSuggestionRow: View {
  let suggestion: TaskBoardSearchSuggestion

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      SearchHighlightedText(
        text: suggestion.title,
        highlights: suggestion.titleHighlights
      )
      .scaledFont(.caption)
      .lineLimit(1)
      .truncationMode(.tail)
      if !suggestion.subtitle.isEmpty {
        Text(suggestion.subtitle)
          .scaledFont(.caption2)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingSM)
    .padding(.vertical, HarnessMonitorTheme.spacingXS + 1)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
