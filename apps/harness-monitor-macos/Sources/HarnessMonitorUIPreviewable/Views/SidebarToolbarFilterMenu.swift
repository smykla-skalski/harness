import HarnessMonitorKit
import SwiftUI

public struct SidebarToolbarFilterMenu: View {
  public let store: HarnessMonitorStore
  public let sessionFilter: HarnessMonitorStore.SessionFilter
  public let sessionFocusFilter: SessionFocusFilter
  public let sessionSortOrder: SessionSortOrder
  public let hasActiveFilters: Bool

  public init(
    store: HarnessMonitorStore,
    sessionFilter: HarnessMonitorStore.SessionFilter,
    sessionFocusFilter: SessionFocusFilter,
    sessionSortOrder: SessionSortOrder,
    hasActiveFilters: Bool
  ) {
    self.store = store
    self.sessionFilter = sessionFilter
    self.sessionFocusFilter = sessionFocusFilter
    self.sessionSortOrder = sessionSortOrder
    self.hasActiveFilters = hasActiveFilters
  }

  public var body: some View {
    Menu {
      Section("Status") {
        ForEach(HarnessMonitorStore.SessionFilter.allCases) { filter in
          filterButton(
            title: filter.title,
            isSelected: sessionFilter == filter,
            identifier: HarnessMonitorAccessibility.sessionFilterButton(filter.rawValue)
          ) {
            store.sessionFilter = filter
          }
        }
      }

      Section("Focus") {
        ForEach(SessionFocusFilter.allCases) { filter in
          filterButton(
            title: filter.title,
            isSelected: sessionFocusFilter == filter,
            identifier: HarnessMonitorAccessibility.sidebarFocusChip(filter.rawValue)
          ) {
            store.sessionFocusFilter = filter
          }
        }
      }

      Section("Sort") {
        ForEach(SessionSortOrder.allCases) { order in
          filterButton(
            title: order.title,
            isSelected: sessionSortOrder == order,
            identifier: HarnessMonitorAccessibility.sidebarSortSegment(order.rawValue)
          ) {
            store.sessionSortOrder = order
          }
        }
      }

      Section {
        Button("Clear Filters") {
          store.searchText = ""
          store.sessionFilter = .all
          store.sessionFocusFilter = .all
          store.sessionSortOrder = .recentActivity
        }
        .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarClearFiltersButton)
        .disabled(!hasActiveFilters)
      }
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
