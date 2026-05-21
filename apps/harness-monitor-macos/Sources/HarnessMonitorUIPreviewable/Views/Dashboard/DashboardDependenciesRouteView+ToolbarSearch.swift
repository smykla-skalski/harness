import HarnessMonitorKit
import SwiftUI

struct DashboardDependenciesSearchSuggestion: Identifiable, Equatable {
  let pullRequestID: String
  let title: String
  let subtitle: String
  let completionKey: String
  let titleHighlights: [SearchHighlightRange]
  let subtitleHighlights: [SearchHighlightRange]

  var id: String { pullRequestID }
}

private struct DashboardDependenciesSearchRecord: Sendable {
  let item: DependencyUpdateItem
  let title: String
  let subtitle: String
  let repository: String
  let author: String
  let numberKey: String
  let labels: [String]
}

private final class DashboardDependenciesSearchIndex {
  private static let fields: [FuzzySearchField<DashboardDependenciesSearchRecord>] = [
    .single("title", weight: 0.8, highlightField: .title, prefixRank: 0) { $0.title },
    .single("subtitle", weight: 0.45, highlightField: .subtitle, prefixRank: 1) {
      $0.subtitle
    },
    .single("repository", weight: 0.45, prefixRank: 1) { $0.repository },
    .single("author", weight: 0.3, prefixRank: 2) { $0.author },
    .single("numberKey", weight: 0.2, prefixRank: 3) { $0.numberKey },
    .multiple("labels", weight: 0.2) { $0.labels },
  ]

  private let searchIndex: FuzzySearchIndex<DashboardDependenciesSearchRecord>

  init(items: [DependencyUpdateItem]) {
    let records = items.map { item in
      let subtitle = "\(item.repository)#\(item.number) · @\(item.authorLogin)"
      return DashboardDependenciesSearchRecord(
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
  ) -> [DashboardDependenciesSearchSuggestion] {
    searchIndex
      .search(query)
      .sorted(by: sortsBefore)
      .prefix(limit)
      .map { entry in
        DashboardDependenciesSearchSuggestion(
          pullRequestID: entry.item.item.pullRequestID,
          title: entry.item.title,
          subtitle: entry.item.subtitle,
          completionKey: entry.item.subtitle,
          titleHighlights: entry.highlights.title,
          subtitleHighlights: entry.highlights.subtitle
        )
      }
  }

  private func sortsBefore(
    _ lhs: FuzzySearchResult<DashboardDependenciesSearchRecord>,
    _ rhs: FuzzySearchResult<DashboardDependenciesSearchRecord>
  ) -> Bool {
    if lhs.score != rhs.score { return lhs.score < rhs.score }
    if lhs.item.repository != rhs.item.repository {
      return lhs.item.repository.localizedCaseInsensitiveCompare(rhs.item.repository)
        == .orderedAscending
    }
    return lhs.item.item.number < rhs.item.item.number
  }
}

private struct DashboardDependenciesSearchIndexSignature: Hashable {
  let count: Int
  let lastID: String?
  let contentFingerprint: Int
}

func dashboardDependenciesSearchSuggestions(
  query: String,
  items: [DependencyUpdateItem],
  limit: Int = 8
) -> [DashboardDependenciesSearchSuggestion] {
  let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return [] }
  return DashboardDependenciesSearchIndex(items: items).suggestions(query: trimmed, limit: limit)
}

extension View {
  func dashboardDependenciesToolbarSearch(
    query: Binding<String>,
    items: [DependencyUpdateItem],
    automation: AppSearchAutomationState? = nil,
    onSelect: @escaping (String) -> Void
  ) -> some View {
    modifier(
      DashboardDependenciesToolbarSearchModifier(
        query: query,
        items: items,
        automation: automation,
        onSelect: onSelect
      )
    )
  }
}

private struct DashboardDependenciesToolbarSearchModifier: ViewModifier {
  @Binding var query: String
  let items: [DependencyUpdateItem]
  let automation: AppSearchAutomationState?
  let onSelect: (String) -> Void

  @FocusState private var isSearchFocused: Bool
  @State private var searchFocusDispatcher = HarnessSidebarSearchFocusDispatcher()
  @State private var searchIndex = DashboardDependenciesSearchIndex(items: [])

  private var suggestions: [DashboardDependenciesSearchSuggestion] {
    guard !HarnessMonitorPerfIsolation.disablesSearchSuggestions else { return [] }
    return searchIndex.suggestions(query: query)
  }

  private var searchIndexSignature: DashboardDependenciesSearchIndexSignature {
    DashboardDependenciesSearchIndexSignature(
      count: items.count,
      lastID: items.last?.pullRequestID,
      contentFingerprint: Self.fingerprint(
        items.flatMap { item in
          [
            item.pullRequestID,
            item.title,
            item.repository,
            item.authorLogin,
            "#\(item.number)",
          ] + item.labels
        }
      )
    )
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
          .buttonStyle(.plain)
        }
      }
      .searchFocused($isSearchFocused)
      .onChange(of: searchIndexSignature, initial: true) { _, _ in
        searchIndex = DashboardDependenciesSearchIndex(items: items)
      }
      .onSubmit(of: .search) {
        submit()
      }
      .focusedSceneValue(\.harnessSidebarSearchFocusAction, searchFocusAction)
      .onAppear {
        searchFocusDispatcher.handler = {
          focusSearchField()
        }
      }
      .task {
        automation?.handler = { command in
          Task { @MainActor in
            await applyAutomationCommand(command)
          }
        }
      }
      .onDisappear {
        automation?.handler = nil
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

  private static func fingerprint(_ values: [String]) -> Int {
    var hasher = Hasher()
    for value in values {
      hasher.combine(value)
    }
    return hasher.finalize()
  }
}
