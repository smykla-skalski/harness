import HarnessMonitorKit
import SwiftUI

struct SidebarToolbarFilterMenu: View {
  let sessionFilter: HarnessMonitorStore.SessionFilter
  let sessionFocusFilter: SessionFocusFilter
  let sessionSortOrder: SessionSortOrder
  let hasActiveFilters: Bool
  let setSessionFilter: (HarnessMonitorStore.SessionFilter) -> Void
  let setSessionFocusFilter: (SessionFocusFilter) -> Void
  let setSessionSortOrder: (SessionSortOrder) -> Void
  let clearFilters: () -> Void

  var body: some View {
    Menu {
      Menu("Status") {
        ForEach(HarnessMonitorStore.SessionFilter.allCases) { filter in
          filterButton(
            title: filter.title,
            isSelected: sessionFilter == filter,
            identifier: HarnessMonitorAccessibility.sessionFilterButton(filter.rawValue)
          ) {
            setSessionFilter(filter)
          }
        }
      }

      Menu("Focus") {
        ForEach(SessionFocusFilter.allCases) { filter in
          filterButton(
            title: filter.title,
            isSelected: sessionFocusFilter == filter,
            identifier: HarnessMonitorAccessibility.sidebarFocusChip(filter.rawValue)
          ) {
            setSessionFocusFilter(filter)
          }
        }
      }

      Menu("Sort") {
        ForEach(SessionSortOrder.allCases) { order in
          filterButton(
            title: order.title,
            isSelected: sessionSortOrder == order,
            identifier: HarnessMonitorAccessibility.sidebarSortSegment(order.rawValue)
          ) {
            setSessionSortOrder(order)
          }
        }
      }

      Divider()

      Button("Clear Filters", action: clearFilters)
        .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarClearFiltersButton)
        .disabled(!hasActiveFilters)
    } label: {
      Label(
        "Filters",
        systemImage: hasActiveFilters
          ? "line.3.horizontal.decrease.circle.fill"
          : "line.3.horizontal.decrease.circle"
      )
    }
    .help("Filter and sort sessions")
    .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarFilterMenu)
  }

  private func filterButton(
    title: String,
    isSelected: Bool,
    identifier: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      if isSelected {
        Label(title, systemImage: "checkmark")
      } else {
        Text(title)
      }
    }
    .accessibilityIdentifier(identifier)
  }
}
