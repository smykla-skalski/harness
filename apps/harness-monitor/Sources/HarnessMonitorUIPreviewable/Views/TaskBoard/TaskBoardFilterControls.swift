import HarnessMonitorKit
import SwiftUI

/// One selected value, as it reads on the row of active filters.
struct TaskBoardActiveFilterChip: Identifiable, Equatable {
  let facet: TaskBoardFilterFacet
  let valueID: String
  let label: String

  var id: String { "\(facet.rawValue):\(valueID)" }

  var title: String { "\(facet.chipPrefix): \(label)" }
}

extension TaskBoardFilterInventory {
  /// Every selected value, facet by facet, in the order the facets are offered.
  func activeChips(for filters: TaskBoardFilterState) -> [TaskBoardActiveFilterChip] {
    TaskBoardFilterFacet.allCases.flatMap { facet -> [TaskBoardActiveFilterChip] in
      options(for: facet)
        .filter { filters.contains($0.id, in: facet) }
        .map {
          TaskBoardActiveFilterChip(facet: facet, valueID: $0.id, label: $0.label)
        }
    }
  }
}

/// The board's filter entry point: a dropdown each for the two facets worth
/// reaching for directly, the rest behind one general control, and a way to
/// switch the whole thing back off.
struct TaskBoardFilterControls: View {
  @Binding var filters: TaskBoardFilterState
  let inventory: TaskBoardFilterInventory

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      ForEach(TaskBoardFilterFacet.dedicated) { facet in
        TaskBoardFacetFilterButton(
          facet: facet,
          filters: $filters,
          options: inventory.options(for: facet)
        )
      }
      TaskBoardGeneralFilterButton(filters: $filters, inventory: inventory)
      if !filters.isEmpty {
        clearButton
      }
    }
  }

  private var clearButton: some View {
    Button("Clear All") {
      filters.clear()
    }
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .harnessNativeFormControl()
    .help("Show every item again")
    .accessibilityIdentifier("harness.task-board.filters.clear")
  }
}

/// One facet on its own button, listing its values under it.
struct TaskBoardFacetFilterButton: View {
  let facet: TaskBoardFilterFacet
  @Binding var filters: TaskBoardFilterState
  let options: [TaskBoardFilterOption]
  @State private var showsOptions = false

  private var selectedCount: Int { filters.valueCount(for: facet) }

  var body: some View {
    Button {
      showsOptions = true
    } label: {
      HStack(spacing: 6) {
        Text(facet.title)
        if selectedCount > 0 {
          Text("\(selectedCount)")
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        Image(systemName: "chevron.down")
          .imageScale(.small)
          .accessibilityHidden(true)
      }
      .scaledFont(.caption.weight(.semibold))
    }
    .harnessActionButtonStyle(
      variant: .bordered,
      tint: selectedCount > 0 ? HarnessMonitorTheme.accent : .secondary
    )
    .harnessNativeFormControl()
    .disabled(options.isEmpty)
    .help("Narrow the board by \(facet.title.lowercased())")
    .accessibilityIdentifier("harness.task-board.filters.\(facet.rawValue)")
    .popover(isPresented: $showsOptions, arrowEdge: .top) {
      TaskBoardFacetFilterOptions(facet: facet, filters: $filters, options: options)
    }
  }
}

/// The general filter: every facet without a button of its own.
struct TaskBoardGeneralFilterButton: View {
  @Binding var filters: TaskBoardFilterState
  let inventory: TaskBoardFilterInventory
  @State private var showsFilterPopover = false

  private var selectedCount: Int {
    filters.activeValueCount(in: TaskBoardFilterFacet.general)
  }

  var body: some View {
    Button {
      showsFilterPopover = true
    } label: {
      HStack(spacing: 6) {
        Label("Filter", systemImage: filterSystemImage)
        if selectedCount > 0 {
          Text("\(selectedCount)")
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
      }
      .scaledFont(.caption.weight(.semibold))
    }
    .harnessActionButtonStyle(
      variant: .bordered,
      tint: selectedCount > 0 ? HarnessMonitorTheme.accent : .secondary
    )
    .harnessNativeFormControl()
    .disabled(!inventory.hasOptions(in: TaskBoardFilterFacet.general))
    .help("Narrow the board by tag or source")
    .accessibilityIdentifier("harness.task-board.filters.open")
    .popover(isPresented: $showsFilterPopover, arrowEdge: .top) {
      TaskBoardFilterPopover(filters: $filters, inventory: inventory)
    }
  }

  private var filterSystemImage: String {
    selectedCount > 0
      ? "line.3.horizontal.decrease.circle.fill"
      : "line.3.horizontal.decrease.circle"
  }
}

/// The active filter, spelled out one value at a time so any single one can go
/// without touching the rest.
struct TaskBoardActiveFilterChips: View {
  @Binding var filters: TaskBoardFilterState
  let chips: [TaskBoardActiveFilterChip]

  var body: some View {
    HarnessMonitorWrapLayout(
      spacing: HarnessMonitorTheme.spacingXS,
      lineSpacing: HarnessMonitorTheme.spacingXS
    ) {
      ForEach(chips) { chip in
        Button {
          filters.remove(chip.valueID, from: chip.facet)
        } label: {
          HStack(spacing: 6) {
            // The facet only says which field this is; the value is what the
            // eye is scanning for, so it carries the weight on its own.
            HStack(spacing: 4) {
              Text("\(chip.facet.chipPrefix):")
                .scaledFont(.caption)
                .layoutPriority(1)
              Text(chip.label)
                .scaledFont(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            }
            Image(systemName: "xmark.circle.fill")
              .imageScale(.small)
          }
        }
        .harnessFilterChipButtonStyle(isSelected: true)
        .harnessNativeFormControl()
        .accessibilityLabel("Remove filter \(chip.title)")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.filters.active")
  }
}
