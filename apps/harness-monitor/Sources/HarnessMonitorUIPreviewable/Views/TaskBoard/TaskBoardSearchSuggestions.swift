import Foundation
import HarnessMonitorKit

/// One card as the suggestions read it.
///
/// The body stays out: a suggestion is a card someone is about to point at, and
/// a hit buried in a long body is not one they would recognize on a single row.
/// The literal match behind the board still reads it.
struct TaskBoardSearchCandidate: Equatable, Sendable, Identifiable {
  let id: String
  let title: String
  let subtitle: String
  let tags: [String]
}

/// One row under the search field.
struct TaskBoardSearchSuggestion: Equatable, Sendable, Identifiable {
  let id: String
  let title: String
  let subtitle: String
  let titleHighlights: [SearchHighlightRange]
}

/// The fuzzy index itself. Reachable outside the worker so a preview can build
/// one and render the same rows the board would, without an actor hop it has no
/// chance to await.
final class TaskBoardSearchSuggestionIndex {
  private static let fields: [FuzzySearchField<TaskBoardSearchCandidate>] = [
    .single("title", weight: 0.75, highlightField: .title, prefixRank: 0) { $0.title },
    .single("subtitle", weight: 0.3, prefixRank: 1) { $0.subtitle },
    .multiple("tags", weight: 0.25) { $0.tags },
  ]

  /// Tighter than the app default. These rows are cards someone is about to
  /// point at, and at the usual tolerance a three-letter query pulls in titles
  /// that merely share those letters somewhere.
  private static let threshold = 0.28

  private let searchIndex: FuzzySearchIndex<TaskBoardSearchCandidate>

  init(candidates: [TaskBoardSearchCandidate]) throws {
    searchIndex = try FuzzySearchIndex(
      items: candidates,
      fields: Self.fields,
      threshold: Self.threshold
    )
  }

  func suggestions(query: String, limit: Int = 6) -> [TaskBoardSearchSuggestion] {
    searchIndex
      .topResults(query, limit: limit)
      .results
      .map { entry in
        TaskBoardSearchSuggestion(
          id: entry.item.id,
          title: entry.item.title,
          subtitle: entry.item.subtitle,
          titleHighlights: entry.highlights.title
        )
      }
  }
}

/// Keeps the fuzzy index off the main actor and alive between keystrokes.
actor TaskBoardSearchSuggestionWorker {
  private var indexedCandidates: [TaskBoardSearchCandidate] = []
  private var searchIndex: TaskBoardSearchSuggestionIndex?

  func suggestions(
    query: String,
    candidates: [TaskBoardSearchCandidate],
    limit: Int = 6
  ) -> [TaskBoardSearchSuggestion] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !candidates.isEmpty, limit > 0 else {
      return []
    }
    if searchIndex == nil || candidates != indexedCandidates {
      searchIndex = try? TaskBoardSearchSuggestionIndex(candidates: candidates)
      indexedCandidates = candidates
    }
    return searchIndex?.suggestions(query: trimmed, limit: limit) ?? []
  }
}
