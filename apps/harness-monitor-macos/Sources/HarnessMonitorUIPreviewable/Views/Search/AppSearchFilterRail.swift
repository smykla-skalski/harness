import HarnessMonitorKit
import SwiftUI

/// Compact horizontal multi-select filter rail rendered as a
/// `.safeAreaInset(edge: .top)` on the session window when the
/// `.searchable` field is presented.
///
/// Each chip is a native `Toggle(isOn:)` + `.toggleStyle(.button)`,
/// the canonical SwiftUI multi-select pattern. The system handles
/// selected/unselected visuals, focus ring, accessibility traits.
/// "All" reflects `selectedDomains.isEmpty`; clicking it always
/// resets to `[]`. Each domain chip toggles its membership.
///
/// The rail is intentionally NOT inside `.searchSuggestions`:
/// SwiftUI's suggestions popover on macOS only hit-tests rows that
/// behave as `Button` suggestion completions, so multi-select
/// Toggles inside the popover lose clicks. Hosting the rail in the
/// safe area keeps it in the search-active chrome where Toggles are
/// fully native.
public struct AppSearchFilterRail: View {
  @Binding var selectedDomains: Set<AppSearchDomain>

  public init(selectedDomains: Binding<Set<AppSearchDomain>>) {
    self._selectedDomains = selectedDomains
  }

  public var body: some View {
    HStack(spacing: 6) {
      Toggle(isOn: allModeBinding) {
        Text("All")
      }
      ForEach(AppSearchDomain.allCases) { domain in
        Toggle(isOn: domainBinding(for: domain)) {
          Text(domain.label)
        }
      }
      Spacer(minLength: 0)
    }
    .toggleStyle(.button)
    .controlSize(.small)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.bar)
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
}
