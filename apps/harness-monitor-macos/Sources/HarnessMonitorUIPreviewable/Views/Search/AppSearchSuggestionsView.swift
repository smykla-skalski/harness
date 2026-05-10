import HarnessMonitorKit
import SwiftUI

/// Sectioned popover content rendered inside `.searchSuggestions { … }`.
///
/// First row is a scope `Menu`; remaining sections are the per-domain
/// search hits. `.current` shows every non-empty section in fallback
/// order (primary first). Picking an explicit scope from the menu
/// narrows the popover to just that domain.
///
/// Each hit row is a `Button` that invokes `routeAction` and dismisses
/// the search field via the environment action — explicit routing is
/// what closes the popover, not the implicit completion path.
///
/// `.searchCompletion(_:)` on each row supplies the title as the
/// keyboard completion so Tab/Enter pre-fills the query without leaving
/// the field.
public struct AppSearchSuggestionsView: View {
  let results: AppSearchResults
  @Binding var scope: AppSearchScope
  let routeAction: (AppSearchHit) -> Void

  @Environment(\.dismissSearch)
  private var dismissSearch

  public init(
    results: AppSearchResults,
    scope: Binding<AppSearchScope>,
    routeAction: @escaping (AppSearchHit) -> Void
  ) {
    self.results = results
    self._scope = scope
    self.routeAction = routeAction
  }

  public var body: some View {
    scopeMenu
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
    guard let domain = scope.explicitDomain else {
      return results.sections
    }
    return results.sections.filter { $0.domain == domain }
  }

  private var scopeMenu: some View {
    Menu {
      Picker("Search scope", selection: $scope) {
        ForEach(AppSearchScope.allCases) { value in
          Text(value.label).tag(value)
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "line.3.horizontal.decrease.circle")
          .foregroundStyle(.secondary)
          .frame(width: 18)
        Text("Search in: \(scope.label)")
        Spacer(minLength: 4)
        Image(systemName: "chevron.down")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .menuStyle(.borderlessButton)
    .accessibilityIdentifier("app-search.scope-menu")
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
    .harnessPlainButtonStyle()
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
