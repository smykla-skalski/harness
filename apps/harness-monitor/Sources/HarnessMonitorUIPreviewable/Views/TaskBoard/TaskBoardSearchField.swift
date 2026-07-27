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
    field
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
      .task(id: suggestionRequest) {
        await refreshSuggestions(for: suggestionRequest)
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
        onSelect: accept
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

  private struct SuggestionRequest: Equatable {
    let query: String
    let isSuggesting: Bool
    let candidateCount: Int
  }

  private var suggestionRequest: SuggestionRequest {
    SuggestionRequest(
      query: text,
      isSuggesting: isSuggesting,
      candidateCount: candidates.count
    )
  }

  private func accept(_ suggestion: TaskBoardSearchSuggestion) {
    text = suggestion.title
    suppressedText = suggestion.title
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
    let matches = await suggestionWorker.suggestions(
      query: request.query,
      candidates: candidates
    )
    guard !Task.isCancelled, request == suggestionRequest else {
      return
    }
    suggestions = matches
  }
}

/// The rows under the field, each one a card someone can point at.
private struct TaskBoardSearchSuggestionList: View {
  let suggestions: [TaskBoardSearchSuggestion]
  let width: CGFloat
  let onSelect: (TaskBoardSearchSuggestion) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(suggestions) { suggestion in
        Button {
          onSelect(suggestion)
        } label: {
          TaskBoardSearchSuggestionRow(suggestion: suggestion)
        }
        .harnessPlainButtonStyle()
        .accessibilityLabel("Search for \(suggestion.title)")
      }
    }
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

private struct TaskBoardSearchSuggestionRow: View {
  let suggestion: TaskBoardSearchSuggestion
  @State private var isHovering = false

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
    .background(
      isHovering ? HarnessMonitorTheme.accent.opacity(0.18) : .clear,
      in: .rect(cornerRadius: HarnessMonitorTheme.spacingSM)
    )
    .contentShape(.rect)
    .onHover { isHovering = $0 }
  }
}
