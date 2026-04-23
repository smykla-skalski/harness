import HarnessMonitorKit
import SwiftUI

struct SidebarFilterMenu: View {
  let store: HarnessMonitorStore
  let controls: HarnessMonitorStore.SessionControlsSlice

  private var hasActiveFilters: Bool {
    SidebarFilterVisibilityPolicy.hasActiveFilters(in: controls)
  }

  private var profilingAttributes: [String: String] {
    [
      "harness.view.has_active_filters": hasActiveFilters ? "true" : "false",
      "harness.view.session_filter": controls.sessionFilter.rawValue,
      "harness.view.focus_filter": controls.sessionFocusFilter.rawValue,
      "harness.view.sort_order": controls.sessionSortOrder.rawValue,
    ]
  }

  private var sessionFilterBinding: Binding<HarnessMonitorStore.SessionFilter> {
    Binding(
      get: { store.sessionFilter },
      set: { store.sessionFilter = $0 }
    )
  }

  private var sessionFocusFilterBinding: Binding<SessionFocusFilter> {
    Binding(
      get: { store.sessionFocusFilter },
      set: { store.sessionFocusFilter = $0 }
    )
  }

  private var sessionSortOrderBinding: Binding<SessionSortOrder> {
    Binding(
      get: { store.sessionSortOrder },
      set: { store.sessionSortOrder = $0 }
    )
  }

  var body: some View {
    ViewBodySignposter.trace(
      Self.self,
      "SidebarFilterMenu",
      attributes: profilingAttributes
    ) {
      Menu {
        Picker("Status", selection: sessionFilterBinding) {
          ForEach(HarnessMonitorStore.SessionFilter.allCases) { filter in
            Text(filter.title).tag(filter)
          }
        }
        .pickerStyle(.inline)
        .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarStatusPicker)

        Picker("Focus", selection: sessionFocusFilterBinding) {
          ForEach(SessionFocusFilter.allCases) { filter in
            Text(filter.title).tag(filter)
          }
        }
        .pickerStyle(.inline)
        .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarFocusPicker)

        Picker("Sort", selection: sessionSortOrderBinding) {
          ForEach(SessionSortOrder.allCases) { order in
            Text(order.title).tag(order)
          }
        }
        .pickerStyle(.inline)
        .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarSortPicker)

        Divider()

        Button("Clear Filters") {
          store.resetFilters()
        }
        .disabled(!hasActiveFilters)
        .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarClearFiltersButton)
      } label: {
        Label(
          "Filter",
          systemImage: hasActiveFilters
            ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
      }
      .harnessGlassButtonStyle()
      .menuIndicator(.hidden)
      .accessibilityLabel("Filters")
      .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarFiltersCard)
    }
  }
}
