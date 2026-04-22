import HarnessMonitorKit
import SwiftUI

struct SidebarSearchControlsSection: View {
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
    Section {
      ViewBodySignposter.trace(
        Self.self,
        "SidebarSearchControlsSection",
        attributes: profilingAttributes
      ) {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          SidebarSearchControlsPickerRow(title: "Status") {
            Picker("Status", selection: sessionFilterBinding) {
              ForEach(HarnessMonitorStore.SessionFilter.allCases) { filter in
                Text(filter.title).tag(filter)
              }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .accessibilityLabel("Status")
            .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarStatusPicker)
          }

          SidebarSearchControlsPickerRow(title: "Focus") {
            Picker("Focus", selection: sessionFocusFilterBinding) {
              ForEach(SessionFocusFilter.allCases) { filter in
                Text(filter.title).tag(filter)
              }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .accessibilityLabel("Focus")
            .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarFocusPicker)
          }

          SidebarSearchControlsPickerRow(title: "Sort") {
            Picker("Sort", selection: sessionSortOrderBinding) {
              ForEach(SessionSortOrder.allCases) { order in
                Text(order.title).tag(order)
              }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .accessibilityLabel("Sort")
            .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarSortPicker)
          }

          Button("Clear Filters") {
            store.resetFilters()
          }
          .buttonStyle(.borderless)
          .disabled(!hasActiveFilters)
          .frame(maxWidth: .infinity, alignment: .trailing)
          .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarClearFiltersButton)
        }
        .padding(.vertical, HarnessMonitorTheme.spacingXS)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarFiltersCard)
        .accessibilityFrameMarker(HarnessMonitorAccessibility.sidebarFiltersCardFrame)
      }
    } header: {
      Text("Filters")
    }
  }
}

private struct SidebarSearchControlsPickerRow<Control: View>: View {
  let title: String
  @ViewBuilder let control: () -> Control

  var body: some View {
    LabeledContent(title) {
      control()
    }
  }
}
