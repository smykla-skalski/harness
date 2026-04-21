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

  var body: some View {
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
    .background(Color(nsColor: .windowBackgroundColor))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarFiltersCard)
    .accessibilityFrameMarker(HarnessMonitorAccessibility.sidebarFiltersCardFrame)
  }
}
