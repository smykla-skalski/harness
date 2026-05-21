import HarnessMonitorKit
import SwiftUI

struct DashboardDependenciesSearchSuggestion: Identifiable, Equatable {
  let pullRequestID: String
  let title: String
  let subtitle: String
  let completionKey: String

  var id: String { pullRequestID }
}

func dashboardDependenciesSearchSuggestions(
  query: String,
  items: [DependencyUpdateItem],
  limit: Int = 8
) -> [DashboardDependenciesSearchSuggestion] {
  let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return [] }
  let needle = trimmed.lowercased()

  struct Scored {
    let item: DependencyUpdateItem
    let score: Int
  }

  var scored: [Scored] = []
  scored.reserveCapacity(items.count)
  for item in items {
    let title = item.title.lowercased()
    let repository = item.repository.lowercased()
    let author = item.authorLogin.lowercased()
    let labels = item.labels.map { $0.lowercased() }
    let numberKey = "#\(item.number)"

    var score = 0
    if title.hasPrefix(needle) {
      score = 100
    } else if repository.hasPrefix(needle) {
      score = 90
    } else if author.hasPrefix(needle) {
      score = 80
    } else if title.contains(needle) {
      score = 60
    } else if repository.contains(needle) {
      score = 55
    } else if numberKey.contains(needle) {
      score = 50
    } else if author.contains(needle) {
      score = 45
    } else if labels.contains(where: { $0.contains(needle) }) {
      score = 40
    }

    if score > 0 {
      scored.append(Scored(item: item, score: score))
    }
  }

  scored.sort { lhs, rhs in
    if lhs.score != rhs.score { return lhs.score > rhs.score }
    if lhs.item.repository != rhs.item.repository {
      return lhs.item.repository.localizedCaseInsensitiveCompare(rhs.item.repository)
        == .orderedAscending
    }
    return lhs.item.number < rhs.item.number
  }

  return scored.prefix(limit).map { entry in
    let item = entry.item
    let subtitle = "\(item.repository)#\(item.number) · @\(item.authorLogin)"
    return DashboardDependenciesSearchSuggestion(
      pullRequestID: item.pullRequestID,
      title: item.title,
      subtitle: subtitle,
      completionKey: subtitle
    )
  }
}

extension View {
  func dashboardDependenciesToolbarSearch(
    query: Binding<String>,
    items: [DependencyUpdateItem],
    onSelect: @escaping (String) -> Void
  ) -> some View {
    modifier(
      DashboardDependenciesToolbarSearchModifier(
        query: query,
        items: items,
        onSelect: onSelect
      )
    )
  }
}

private struct DashboardDependenciesToolbarSearchModifier: ViewModifier {
  @Binding var query: String
  let items: [DependencyUpdateItem]
  let onSelect: (String) -> Void

  private var suggestions: [DashboardDependenciesSearchSuggestion] {
    guard !HarnessMonitorPerfIsolation.disablesSearchSuggestions else { return [] }
    return dashboardDependenciesSearchSuggestions(query: query, items: items)
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
          VStack(alignment: .leading, spacing: 2) {
            Text(suggestion.title)
              .lineLimit(1)
            Text(suggestion.subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          .searchCompletion(suggestion.completionKey)
        }
      }
      .onChange(of: query) { oldValue, newValue in
        routeIfCompletionPicked(from: oldValue, to: newValue)
      }
      .onSubmit(of: .search) {
        submit()
      }
  }

  private func routeIfCompletionPicked(from oldValue: String, to newValue: String) {
    let oldTrimmed = oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let newTrimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard newTrimmed != oldTrimmed, !newTrimmed.isEmpty else { return }
    let suggestions = dashboardDependenciesSearchSuggestions(query: newTrimmed, items: items)
    guard let hit = suggestions.first(where: { $0.completionKey == newTrimmed }) else { return }
    deliver(pullRequestID: hit.pullRequestID)
  }

  private func submit() {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let suggestions = dashboardDependenciesSearchSuggestions(query: trimmed, items: items)
    guard let first = suggestions.first else { return }
    deliver(pullRequestID: first.pullRequestID)
  }

  private func deliver(pullRequestID: String) {
    onSelect(pullRequestID)
    if !query.isEmpty {
      query = ""
    }
  }
}
