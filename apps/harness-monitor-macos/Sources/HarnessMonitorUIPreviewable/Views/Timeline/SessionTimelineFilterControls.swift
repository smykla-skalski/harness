import HarnessMonitorKit
import SwiftUI

struct SessionTimelineFilterControls: View {
  enum Layout {
    case stacked
    case chipsOnly
  }

  @Binding private var filters: SessionTimelineFilterState
  private let inventory: SessionTimelineFilterInventory
  private let summary: SessionTimelineFilterSummary
  private let layout: Layout

  init(
    filters: Binding<SessionTimelineFilterState>,
    inventory: SessionTimelineFilterInventory,
    summary: SessionTimelineFilterSummary,
    layout: Layout = .stacked
  ) {
    _filters = filters
    self.inventory = inventory
    self.summary = summary
    self.layout = layout
  }

  private var activeFacetChips: [SessionTimelineActiveFilterChip] {
    var chips: [SessionTimelineActiveFilterChip] = []
    for option in inventory.eventTypes where filters.eventTypes.contains(option.id) {
      chips.append(.eventType(option))
    }
    for option in inventory.agents where filters.agents.contains(option.id) {
      chips.append(.agent(option))
    }
    for option in inventory.tasks where filters.tasks.contains(option.id) {
      chips.append(.task(option))
    }
    for option in inventory.decisionSeverities {
      guard filters.decisionSeverities.contains(option.id) else {
        continue
      }
      chips.append(.decisionSeverity(option))
    }
    for option in inventory.semanticProperties {
      guard containsSemanticProperty(optionID: option.id) else {
        continue
      }
      chips.append(.semanticProperty(option))
    }
    for option in inventory.rawPayloadKeys where filters.rawPayloadKeys.contains(option.id) {
      chips.append(.rawField(option))
    }
    return chips
  }

  private var showsSignalPreset: Bool {
    inventory.signalCount > 0 || filters.signalPresetActive
  }

  private var showsActionRow: Bool {
    layout == .stacked
  }

  private var showsSupportingSections: Bool {
    showsSignalPreset || !activeFacetChips.isEmpty
  }

  @ViewBuilder
  var body: some View {
    if showsActionRow || showsSupportingSections {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        if showsActionRow {
          filterActionRow
        }

        if showsSignalPreset {
          signalPresetSection
        }

        if !activeFacetChips.isEmpty {
          activeFiltersSection
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionTimelineFilterBar)
      .overlay {
        AccessibilityTextMarker(
          identifier: HarnessMonitorAccessibility.sessionTimelineFilterState,
          text: summary.accessibilityState
        )
      }
    }
  }

  private var filterActionRow: some View {
    SessionTimelineFilterActionButtons(filters: $filters, inventory: inventory)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var signalPresetSection: some View {
    HarnessMonitorWrapLayout(
      spacing: HarnessMonitorTheme.spacingXS,
      lineSpacing: HarnessMonitorTheme.spacingXS
    ) {
      if showsSignalPreset {
        Button {
          filters.toggleSignalPreset()
        } label: {
          HStack(spacing: 6) {
            Text("Signals")
            Text("\(inventory.signalCount)")
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
          .scaledFont(.caption.weight(.semibold))
        }
        .harnessFilterChipButtonStyle(isSelected: filters.signalPresetActive)
        .harnessNativeFormControl()
        .accessibilityValue(filters.signalPresetActive ? "selected" : "not selected")
        .accessibilityIdentifier(HarnessMonitorAccessibility.sessionTimelineFilterSignalsPreset)
      }
    }
  }

  private var activeFiltersSection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      sectionLabel("Active filters")
      HarnessMonitorWrapLayout(
        spacing: HarnessMonitorTheme.spacingXS,
        lineSpacing: HarnessMonitorTheme.spacingXS
      ) {
        ForEach(activeFacetChips) { chip in
          Button {
            chip.remove(from: &filters)
          } label: {
            HStack(spacing: 6) {
              Text(chip.label)
                .lineLimit(1)
                .truncationMode(.tail)
              Image(systemName: "xmark.circle.fill")
                .imageScale(.small)
            }
            .scaledFont(.caption.weight(.semibold))
          }
          .harnessFilterChipButtonStyle(isSelected: true)
          .harnessNativeFormControl()
          .accessibilityLabel("Remove filter \(chip.label)")
        }
      }
    }
  }

  private func sectionLabel(_ title: String) -> some View {
    Text(title)
      .scaledFont(.caption.weight(.semibold))
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
  }

  private func containsSemanticProperty(optionID: String) -> Bool {
    guard let property = SessionTimelineSemanticProperty(rawValue: optionID) else {
      return false
    }
    return filters.semanticProperties.contains(property)
  }
}

struct SessionTimelineFilterActionButtons: View {
  @Binding private var filters: SessionTimelineFilterState
  private let inventory: SessionTimelineFilterInventory
  private let showsClearButton: Bool
  @State private var showsAdvancedFilters = false

  init(
    filters: Binding<SessionTimelineFilterState>,
    inventory: SessionTimelineFilterInventory,
    showsClearButton: Bool = true
  ) {
    _filters = filters
    self.inventory = inventory
    self.showsClearButton = showsClearButton
  }

  private var moreFiltersSystemImage: String {
    filters.activeAdvancedFilterCount > 0
      ? "line.3.horizontal.decrease.circle.fill"
      : "line.3.horizontal.decrease.circle"
  }

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      moreFiltersButton
      if showsClearButton {
        clearFiltersButton
      }
    }
  }

  private var moreFiltersButton: some View {
    Button("Filters", systemImage: moreFiltersSystemImage) {
      showsAdvancedFilters = true
    }
    .harnessActionButtonStyle(
      variant: .bordered,
      tint: filters.activeAdvancedFilterCount > 0 ? nil : .secondary
    )
    .harnessNativeFormControl()
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionTimelineFilterMoreButton)
    .popover(isPresented: $showsAdvancedFilters, arrowEdge: .top) {
      SessionTimelineAdvancedFiltersPopover(filters: $filters, inventory: inventory)
    }
  }

  private var clearFiltersButton: some View {
    Button("Clear") {
      filters.clear()
    }
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .harnessNativeFormControl()
    .disabled(filters.isEmpty)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionTimelineFilterClearButton)
  }
}
