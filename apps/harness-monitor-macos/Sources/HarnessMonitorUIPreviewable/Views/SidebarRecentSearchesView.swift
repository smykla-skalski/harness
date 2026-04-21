import HarnessMonitorKit
import SwiftUI

struct SidebarSearchAccessoryBar: View {
  let store: HarnessMonitorStore
  let controls: HarnessMonitorStore.SessionControlsSlice

  private var hasActiveFilters: Bool {
    !controls.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || controls.sessionFilter != .all
      || controls.sessionFocusFilter != .all
      || controls.sessionSortOrder != .recentActivity
  }

  private var profilingAttributes: [String: String] {
    [
      "harness.view.has_active_filters": hasActiveFilters ? "true" : "false",
      "harness.view.session_filter": controls.sessionFilter.rawValue,
      "harness.view.focus_filter": controls.sessionFocusFilter.rawValue,
      "harness.view.sort_order": controls.sessionSortOrder.rawValue,
    ]
  }

  var body: some View {
    ViewBodySignposter.trace(
      Self.self,
      "SidebarSearchAccessoryBar",
      attributes: profilingAttributes
    ) {
      VStack(spacing: 0) {
        HStack(spacing: HarnessMonitorTheme.spacingSM) {
          SidebarToolbarFilterMenu(
            store: store,
            sessionFilter: controls.sessionFilter,
            sessionFocusFilter: controls.sessionFocusFilter,
            sessionSortOrder: controls.sessionSortOrder,
            hasActiveFilters: hasActiveFilters
          )

          Spacer(minLength: 0)
        }
        .padding(.horizontal, HarnessMonitorTheme.spacingMD)
        .padding(.vertical, HarnessMonitorTheme.spacingXS)

        Divider()
          .accessibilityHidden(true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarFiltersCard)
      .accessibilityFrameMarker(HarnessMonitorAccessibility.sidebarFiltersCardFrame)
    }
  }
}
