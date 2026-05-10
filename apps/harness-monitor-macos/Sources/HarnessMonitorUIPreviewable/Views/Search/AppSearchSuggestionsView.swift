import HarnessMonitorKit
import SwiftUI

/// Sectioned popover content rendered inside `.searchSuggestions { … }`.
///
/// Sections are already ordered (primary first) by ``AppSearchIndex``; the
/// view only renders. Each row is a `Button` that invokes `routeAction`
/// and dismisses the search field via the environment action — explicit
/// routing is what closes the popover, not the implicit completion path.
///
/// `.searchCompletion(_:)` on each row supplies the title as the keyboard
/// completion so Tab/Enter pre-fills the query without leaving the field.
public struct AppSearchSuggestionsView: View {
  let results: AppSearchResults
  let routeAction: (AppSearchHit) -> Void

  @Environment(\.dismissSearch)
  private var dismissSearch

  public init(
    results: AppSearchResults,
    routeAction: @escaping (AppSearchHit) -> Void
  ) {
    self.results = results
    self.routeAction = routeAction
  }

  public var body: some View {
    if results.isEmpty {
      EmptyView()
    } else {
      ForEach(results.sections) { section in
        Section {
          ForEach(section.hits) { hit in
            row(for: hit)
          }
        } header: {
          sectionHeader(section)
        }
      }
    }
  }

  private func row(for hit: AppSearchHit) -> some View {
    Button {
      routeAction(hit)
      dismissSearch()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: hit.systemImage)
          .foregroundStyle(.secondary)
          .frame(width: 18)
        VStack(alignment: .leading, spacing: 1) {
          Text(hit.title)
          if let subtitle = hit.subtitle, !subtitle.isEmpty {
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .buttonStyle(.plain)
    .searchCompletion(hit.title)
  }

  private func sectionHeader(_ section: AppSearchSection) -> some View {
    HStack(spacing: 6) {
      Image(systemName: section.domain.systemImage)
      Text(section.domain.label)
      if section.truncated {
        Spacer(minLength: 4)
        Text("Top \(section.hits.count)")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }
}
