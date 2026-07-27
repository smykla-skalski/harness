import HarnessMonitorKit
import SwiftUI

/// Every facet without a button of its own, each value carrying the number of
/// cards it would leave.
struct TaskBoardFilterPopover: View {
  @Binding var filters: TaskBoardFilterState
  let inventory: TaskBoardFilterInventory
  @Environment(\.fontScale)
  private var fontScale

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
        header
        if inventory.hasOptions(in: TaskBoardFilterFacet.general) {
          ForEach(TaskBoardFilterFacet.general) { facet in
            facetSection(facet)
          }
        } else {
          Text("Nothing on the board to narrow by yet.")
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
      }
      .padding(HarnessMonitorTheme.spacingLG)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(
      minWidth: 360 * popoverScale,
      idealWidth: 400 * popoverScale,
      maxWidth: 460 * popoverScale,
      minHeight: 200 * popoverScale,
      idealHeight: 320 * popoverScale
    )
    .accessibilityIdentifier("harness.task-board.filters.popover")
  }

  private var header: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Filter")
        .scaledFont(.headline)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: HarnessMonitorTheme.spacingLG)
      // Names its whole reach, so it never reads as another section's Clear.
      Button("Clear All") {
        filters.clear()
      }
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      .harnessNativeFormControl()
      .disabled(filters.isEmpty)
      .accessibilityLabel("Clear every filter")
      .accessibilityIdentifier("harness.task-board.filters.popover.clear")
    }
  }

  @ViewBuilder private func facetSection(_ facet: TaskBoardFilterFacet) -> some View {
    let options = inventory.options(for: facet)
    if !options.isEmpty {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        TaskBoardFilterFacetHeader(facet: facet, filters: $filters)
        TaskBoardFilterOptionGrid(
          options: options,
          facet: facet,
          filters: $filters,
          scale: popoverScale
        )
      }
    }
  }

  private var popoverScale: CGFloat {
    max(1, min(fontScale, 1.2))
  }
}

/// One facet's values, hanging under that facet's own button.
struct TaskBoardFacetFilterOptions: View {
  let facet: TaskBoardFilterFacet
  @Binding var filters: TaskBoardFilterState
  let options: [TaskBoardFilterOption]
  @Environment(\.fontScale)
  private var fontScale

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        TaskBoardFilterFacetHeader(facet: facet, filters: $filters)
        TaskBoardFilterOptionGrid(
          options: options,
          facet: facet,
          filters: $filters,
          scale: popoverScale,
          layout: .column
        )
      }
      .padding(HarnessMonitorTheme.spacingLG)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(
      minWidth: 240 * popoverScale,
      idealWidth: 300 * popoverScale,
      maxWidth: 380 * popoverScale,
      // One row per value plus the heading, so the dropdown ends where its
      // options do instead of trailing empty space under them.
      idealHeight: min(CGFloat(options.count) * 24 + 56, 420) * popoverScale
    )
    .accessibilityIdentifier("harness.task-board.filters.\(facet.rawValue).options")
  }

  private var popoverScale: CGFloat {
    max(1, min(fontScale, 1.2))
  }
}
