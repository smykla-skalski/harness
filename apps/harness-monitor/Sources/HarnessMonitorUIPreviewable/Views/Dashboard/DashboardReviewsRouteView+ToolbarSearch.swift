import HarnessMonitorKit
import SwiftUI

struct DashboardReviewsSearchSuggestion: Identifiable, Equatable {
  let pullRequestID: String
  let title: String
  let subtitle: String
  let completionKey: String
  let titleHighlights: [SearchHighlightRange]
  let subtitleHighlights: [SearchHighlightRange]

  var id: String { pullRequestID }
}

private struct DashboardReviewsSearchRecord: Sendable {
  let item: ReviewItem
  let title: String
  let subtitle: String
  let repository: String
  let author: String
  let numberKey: String
  let labels: [String]
}

private final class DashboardReviewsSearchIndex {
  private static let fields: [FuzzySearchField<DashboardReviewsSearchRecord>] = [
    .single("title", weight: 0.8, highlightField: .title, prefixRank: 0) { $0.title },
    .single("subtitle", weight: 0.45, highlightField: .subtitle, prefixRank: 1) {
      $0.subtitle
    },
    .single("repository", weight: 0.45, prefixRank: 1) { $0.repository },
    .single("author", weight: 0.3, prefixRank: 2) { $0.author },
    .single("numberKey", weight: 0.2, prefixRank: 3) { $0.numberKey },
    .multiple("labels", weight: 0.2) { $0.labels },
  ]

  private let searchIndex: FuzzySearchIndex<DashboardReviewsSearchRecord>

  init(items: [ReviewItem]) {
    let records = items.map { item in
      let subtitle = "\(item.repository)#\(item.number) · @\(item.authorLogin)"
      return DashboardReviewsSearchRecord(
        item: item,
        title: item.title,
        subtitle: subtitle,
        repository: item.repository,
        author: item.authorLogin,
        numberKey: "#\(item.number)",
        labels: item.labels
      )
    }
    do {
      searchIndex = try FuzzySearchIndex(items: records, fields: Self.fields)
    } catch {
      preconditionFailure("Failed to build dashboard fuzzy search index: \(error)")
    }
  }

  func suggestions(
    query: String,
    limit: Int = 8
  ) -> [DashboardReviewsSearchSuggestion] {
    guard limit > 0 else { return [] }

    return
      searchIndex
      .topResults(
        query,
        limit: limit,
        sortedBy: candidateSortsBefore
      )
      .results
      .map { entry in
        DashboardReviewsSearchSuggestion(
          pullRequestID: entry.item.item.pullRequestID,
          title: entry.item.title,
          subtitle: entry.item.subtitle,
          completionKey: entry.item.subtitle,
          titleHighlights: entry.highlights.title,
          subtitleHighlights: entry.highlights.subtitle
        )
      }
  }

  private func candidateSortsBefore(
    _ lhs: FuzzySearchCandidate<DashboardReviewsSearchRecord>,
    _ rhs: FuzzySearchCandidate<DashboardReviewsSearchRecord>
  ) -> Bool {
    if lhs.score != rhs.score { return lhs.score < rhs.score }
    if lhs.item.repository != rhs.item.repository {
      return lhs.item.repository.localizedCaseInsensitiveCompare(rhs.item.repository)
        == .orderedAscending
    }
    return lhs.item.item.number < rhs.item.item.number
  }
}

struct DashboardReviewsSearchIndexSignature: Hashable {
  let count: Int
  let contentFingerprint: Int
}

// Build an order-independent signature for the search-index inputs. Each
// item's per-field tuple is hashed independently and then folded together with
// overflow-wrapped addition so reordering the input produces the same combined
// fingerprint. Addition is associative and commutative (so order is ignored)
// and unlike XOR it does not collapse duplicate hashes to zero. This keeps the
// `DashboardReviewsSearchIndex` from rebuilding when only the presentation
// order changes (filter/sort flips) but content is unchanged.
func dashboardReviewsSearchIndexSignature(
  items: [ReviewItem]
) -> DashboardReviewsSearchIndexSignature {
  var combined: Int = 0
  for item in items {
    var hasher = Hasher()
    hasher.combine(item.pullRequestID)
    hasher.combine(item.title)
    hasher.combine(item.repository)
    hasher.combine(item.authorLogin)
    hasher.combine(item.number)
    hasher.combine(item.labels)
    combined = combined &+ hasher.finalize()
  }
  return DashboardReviewsSearchIndexSignature(
    count: items.count,
    contentFingerprint: combined
  )
}

func dashboardReviewsSearchSuggestions(
  query: String,
  items: [ReviewItem],
  limit: Int = 8
) -> [DashboardReviewsSearchSuggestion] {
  let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return [] }
  return DashboardReviewsSearchIndex(items: items).suggestions(query: trimmed, limit: limit)
}

extension View {
  func dashboardReviewsToolbarSearch(
    query: Binding<String>,
    items: [ReviewItem],
    automationCommand: AppSearchAutomationCommand? = nil,
    onSelect: @escaping (String) -> Void
  ) -> some View {
    modifier(
      DashboardReviewsToolbarSearchModifier(
        query: query,
        items: items,
        automationCommand: automationCommand,
        onSelect: onSelect
      )
    )
  }
}

private struct DashboardReviewsToolbarSearchModifier: ViewModifier {
  @Binding var query: String
  let items: [ReviewItem]
  let automationCommand: AppSearchAutomationCommand?
  let onSelect: (String) -> Void

  @FocusState private var isSearchFocused: Bool
  @State private var searchFocusDispatcher = HarnessSidebarSearchFocusDispatcher()
  @State private var searchIndex = DashboardReviewsSearchIndex(items: [])

  private var suggestions: [DashboardReviewsSearchSuggestion] {
    guard !HarnessMonitorPerfIsolation.disablesSearchSuggestions else { return [] }
    return searchIndex.suggestions(query: query)
  }

  private var searchIndexSignature: DashboardReviewsSearchIndexSignature {
    dashboardReviewsSearchIndexSignature(items: items)
  }

  private var searchFocusAction: HarnessSidebarSearchFocus {
    HarnessSidebarSearchFocus(
      isAvailable: true,
      menuLabel: .findGeneric,
      dispatcher: searchFocusDispatcher
    )
  }

  func body(content: Content) -> some View {
    content
      .searchable(
        text: $query,
        placement: .toolbar,
        prompt: Text("Search repos, titles, authors, or labels")
      )
      .searchSuggestions {
        ForEach(suggestions) { suggestion in
          Button {
            deliver(pullRequestID: suggestion.pullRequestID)
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              SearchHighlightedText(
                text: suggestion.title,
                highlights: suggestion.titleHighlights
              )
              .lineLimit(1)
              SearchHighlightedText(
                text: suggestion.subtitle,
                highlights: suggestion.subtitleHighlights
              )
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
          }
          .harnessPlainButtonStyle()
        }
      }
      .searchFocused($isSearchFocused)
      // Use `.task(id:)` instead of `.onChange(initial: true)` so the
      // first index build runs *after* the route's initial layout commits.
      // Building synchronously during appear churns `.searchSuggestions`
      // while AppKit's toolbar is still applying its first-pass changes,
      // which trips `_NSDetectedLayoutRecursion` (the WarnOnce that fires
      // ~2 s after window restoration). Empty-query suggestions are `[]`
      // anyway, so the brief empty-index window is invisible.
      .task(id: searchIndexSignature) {
        searchIndex = DashboardReviewsSearchIndex(items: items)
      }
      .onSubmit(of: .search) {
        submit()
      }
      .harnessFocusedSceneValue(\.harnessSidebarSearchFocusAction, searchFocusAction)
      .onAppear {
        searchFocusDispatcher.handler = {
          focusSearchField()
        }
      }
      .task(id: automationCommand?.generation ?? 0) {
        guard let automationCommand else { return }
        await applyAutomationCommand(automationCommand)
      }
  }

  private func focusSearchField() {
    guard !isSearchFocused else { return }
    isSearchFocused = true
  }

  private func submit() {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard let first = suggestions.first else { return }
    deliver(pullRequestID: first.pullRequestID)
  }

  private func deliver(pullRequestID: String) {
    onSelect(pullRequestID)
    if !query.isEmpty {
      query = ""
    }
    if isSearchFocused {
      isSearchFocused = false
    }
  }

  private func applyAutomationCommand(_ command: AppSearchAutomationCommand) async {
    if query != command.query {
      query = command.query
      await Task.yield()
    }
    if isSearchFocused != command.isPresented {
      isSearchFocused = command.isPresented
    }
  }

}
