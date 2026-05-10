import HarnessMonitorKit
import SwiftUI

/// Sectioned popover content rendered inside `.searchSuggestions { … }`.
///
/// The first row is a multi-select filter rail: an "All" button plus
/// one button per ``AppSearchDomain``. "All" clears the selection (=
/// show every non-empty section); any combination of the four domain
/// buttons narrows the popover to those domains.
///
/// Below the rail, each hit row is a native `Button` so SwiftUI's
/// built-in arrow-key navigation in `.searchSuggestions` lands focus
/// on it. Pressing Return invokes `routeAction` and dismisses the
/// search field via the environment action. `.searchCompletion(_:)`
/// supplies the title as the keyboard completion so Tab pre-fills
/// the query without leaving the field.
public struct AppSearchSuggestionsView: View {
  let results: AppSearchResults
  @Binding var selectedDomains: Set<AppSearchDomain>
  let routeAction: (AppSearchHit) -> Void

  @Environment(\.dismissSearch)
  private var dismissSearch

  public init(
    results: AppSearchResults,
    selectedDomains: Binding<Set<AppSearchDomain>>,
    routeAction: @escaping (AppSearchHit) -> Void
  ) {
    self.results = results
    self._selectedDomains = selectedDomains
    self.routeAction = routeAction
  }

  public var body: some View {
    filterRail
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

  private var filterRail: some View {
    HStack(spacing: 6) {
      Toggle(isOn: allModeBinding) {
        Label("All", systemImage: "square.grid.2x2")
      }
      ForEach(AppSearchDomain.allCases) { domain in
        Toggle(isOn: domainBinding(for: domain)) {
          Label(domain.label, systemImage: domain.systemImage)
        }
      }
    }
    .toggleStyle(.button)
    .controlSize(.small)
    .padding(.vertical, 2)
    .accessibilityIdentifier("app-search.filter-rail")
  }

  private var allModeBinding: Binding<Bool> {
    Binding(
      get: { selectedDomains.isEmpty },
      set: { _ in selectedDomains = [] }
    )
  }

  private func domainBinding(for domain: AppSearchDomain) -> Binding<Bool> {
    Binding(
      get: { selectedDomains.contains(domain) },
      set: { isOn in
        if isOn {
          selectedDomains.insert(domain)
        } else {
          selectedDomains.remove(domain)
        }
      }
    )
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
