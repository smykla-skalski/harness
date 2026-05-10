import HarnessMonitorKit
import SwiftUI

/// Sectioned popover content rendered inside `.searchSuggestions { … }`.
///
/// Each hit row is a native `Button`. Pressing Return invokes
/// `routeAction` and dismisses the search field via
/// `Environment(\.dismissSearch)`. `.searchCompletion(_:)` supplies
/// the title as the keyboard completion so Tab pre-fills the query
/// without leaving the field.
///
/// The multi-select filter rail lives outside this view (in
/// ``AppSearchHostModifier`` via `.safeAreaInset(edge: .top)`) so
/// `Toggle(.button)` chips remain clickable — `.searchSuggestions`
/// content rows on macOS only hit-test reliably for Buttons that
/// behave as suggestion completions.
public struct AppSearchSuggestionsView: View {
  let results: AppSearchResults
  let selectedDomains: Set<AppSearchDomain>
  let routeAction: (AppSearchHit) -> Void

  @Environment(\.dismissSearch)
  private var dismissSearch

  public init(
    results: AppSearchResults,
    selectedDomains: Set<AppSearchDomain>,
    routeAction: @escaping (AppSearchHit) -> Void
  ) {
    self.results = results
    self.selectedDomains = selectedDomains
    self.routeAction = routeAction
  }

  public var body: some View {
    ForEach(visibleSections) { section in
      Section {
        ForEach(section.hits) { hit in
          row(for: hit)
        }
      } header: {
        sectionHeader(section)
      }
    }
  }

  private var visibleSections: [AppSearchSection] {
    guard !selectedDomains.isEmpty else {
      return results.sections
    }
    return results.sections.filter { selectedDomains.contains($0.domain) }
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
    .searchCompletion(hit.title)
  }

  private func sectionHeader(_ section: AppSearchSection) -> some View {
    HStack(spacing: 6) {
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
