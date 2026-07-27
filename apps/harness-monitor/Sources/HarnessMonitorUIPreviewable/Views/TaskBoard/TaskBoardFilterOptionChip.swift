import SwiftUI

/// One filter value and the number of cards it would leave.
struct TaskBoardFilterOptionChip: View {
  let option: TaskBoardFilterOption
  let facet: TaskBoardFilterFacet
  @Binding var filters: TaskBoardFilterState

  private var isSelected: Bool { filters.contains(option.id, in: facet) }

  var body: some View {
    Button {
      filters.toggle(option.id, in: facet)
    } label: {
      HStack(spacing: 6) {
        Text(option.label)
          .lineLimit(1)
          .truncationMode(.tail)
        Text("\(option.count)")
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .scaledFont(.caption.weight(.semibold))
    }
    .harnessFilterChipButtonStyle(isSelected: isSelected)
    .harnessNativeFormControl()
    .help(helpText)
    .accessibilityValue(isSelected ? "selected" : "not selected")
  }

  private var helpText: String {
    option.count == 1
      ? "1 item matches \(option.label)"
      : "\(option.count) items match \(option.label)"
  }
}

/// A facet's heading, with the way to drop just that facet's selection.
struct TaskBoardFilterFacetHeader: View {
  let facet: TaskBoardFilterFacet
  @Binding var filters: TaskBoardFilterState

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      Text(facet.title)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      if !filters.isEmpty(facet: facet) {
        Button("Clear") {
          filters.clear(facet)
        }
        .buttonStyle(.link)
        .scaledFont(.caption)
        .accessibilityLabel("Clear the \(facet.title) filter")
      }
    }
  }
}

/// The grid every facet lays its values out in.
struct TaskBoardFilterOptionGrid: View {
  /// One facet on its own gets a single full-width column, so its values end
  /// where its heading's Clear does. Several facets sharing a popover pack into
  /// as many columns as fit.
  enum Layout {
    case column
    case packed
  }

  let options: [TaskBoardFilterOption]
  let facet: TaskBoardFilterFacet
  @Binding var filters: TaskBoardFilterState
  let scale: CGFloat
  var layout: Layout = .packed

  var body: some View {
    LazyVGrid(
      columns: gridColumns,
      alignment: .leading,
      spacing: HarnessMonitorTheme.spacingXS
    ) {
      ForEach(options) { option in
        TaskBoardFilterOptionChip(option: option, facet: facet, filters: $filters)
      }
    }
  }

  private var gridColumns: [GridItem] {
    switch layout {
    case .column:
      [GridItem(.flexible(), spacing: HarnessMonitorTheme.spacingXS)]
    case .packed:
      [
        GridItem(
          .adaptive(minimum: 140 * scale, maximum: 220 * scale),
          spacing: HarnessMonitorTheme.spacingXS
        )
      ]
    }
  }
}
