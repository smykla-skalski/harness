import HarnessMonitorKit
import SwiftUI

/// Sectioned popover content rendered inside `.searchSuggestions { … }`.
///
/// The first section is a multi-select filter list: an "All" row plus
/// one row per ``AppSearchDomain``. Each row is a native `Button` —
/// the only interactive primitive `.searchSuggestions` reliably
/// hit-tests on macOS. A leading checkmark indicates selection.
/// "All" clears the set; any combination of domain rows narrows the
/// popover to those domains.
///
/// Below the filter section, each hit row is a `Button`. Pressing
/// Return invokes `routeAction` and dismisses the search field via
/// `Environment(\.dismissSearch)`. `.searchCompletion(_:)` supplies
/// the title as the keyboard completion so Tab pre-fills the query
/// without leaving the field.
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
    Section("Filter by") {
      filterRow(
        label: "All",
        isSelected: selectedDomains.isEmpty
      ) {
        selectedDomains = []
      }
      ForEach(AppSearchDomain.allCases) { domain in
        filterRow(
          label: domain.label,
          isSelected: selectedDomains.contains(domain)
        ) {
          toggle(domain)
        }
      }
    }
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

  private func toggle(_ domain: AppSearchDomain) {
    if selectedDomains.contains(domain) {
      selectedDomains.remove(domain)
    } else {
      selectedDomains.insert(domain)
    }
  }

  private func filterRow(
    label: String,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: isSelected ? "checkmark" : "circle")
          .foregroundStyle(isSelected ? Color.accentColor : .secondary)
          .frame(width: 18)
        Text(label)
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
