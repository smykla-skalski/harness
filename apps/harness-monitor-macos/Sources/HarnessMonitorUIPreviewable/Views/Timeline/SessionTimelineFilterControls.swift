import HarnessMonitorKit
import SwiftUI

struct SessionTimelineFilterControls: View {
  @Binding private var filters: SessionTimelineFilterState
  private let inventory: SessionTimelineFilterInventory
  private let summary: SessionTimelineFilterSummary

  @Environment(\.fontScale)
  private var fontScale
  @State private var showsAdvancedFilters = false

  init(
    filters: Binding<SessionTimelineFilterState>,
    inventory: SessionTimelineFilterInventory,
    summary: SessionTimelineFilterSummary
  ) {
    _filters = filters
    self.inventory = inventory
    self.summary = summary
  }

  private var quickTones: [SessionTimelineTone] {
    SessionTimelineTone.allCases.filter { tone in
      inventory.toneCounts.keys.contains(tone) || filters.tones.contains(tone)
    }
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

  private var moreFiltersSystemImage: String {
    filters.activeAdvancedFilterCount > 0
      ? "line.3.horizontal.decrease.circle.fill"
      : "line.3.horizontal.decrease.circle"
  }

  private var showsSignalPreset: Bool {
    inventory.signalCount > 0 || filters.signalPresetActive
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      searchControls

      if showsSignalPreset || !quickTones.isEmpty {
        presetAndToneChipsSection
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

  private var searchControls: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingXS) {
        searchField
        searchAccessoryRow
      }
      .frame(
        minWidth: SessionTimelineFilterControlLayout.horizontalMinimumWidth(
          fontScale: fontScale
        ),
        alignment: .leading
      )

      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        searchField
        HarnessMonitorWrapLayout(
          spacing: HarnessMonitorTheme.spacingXS,
          lineSpacing: HarnessMonitorTheme.spacingXS
        ) {
          scopeMenu
          moreFiltersButton
          clearFiltersButton
        }
      }
    }
  }

  private var searchAccessoryRow: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingXS) {
      scopeMenu
      moreFiltersButton
      clearFiltersButton
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private var searchField: some View {
    SessionTimelineSearchField(query: $filters.query)
      .frame(maxWidth: .infinity)
      .layoutPriority(1)
  }

  private var scopeMenu: some View {
    Menu {
      ForEach(SessionTimelineSearchScope.allCases) { scope in
        Button {
          filters.searchScope = scope
        } label: {
          scopeMenuItem(scope)
        }
      }
    } label: {
      Label(filters.searchScope.label, systemImage: filters.searchScope.systemImage)
        .labelStyle(.titleAndIcon)
    }
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .harnessNativeFormControl()
    .accessibilityLabel("Search scope — \(filters.searchScope.label)")
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionTimelineFilterScopeMenu)
  }

  private func scopeMenuItem(_ scope: SessionTimelineSearchScope) -> some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: filters.searchScope == scope ? "checkmark" : scope.systemImage)
      Text(scope.label)
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

  private var presetAndToneChipsSection: some View {
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

      if !quickTones.isEmpty {
        Button("All levels") {
          filters.clearTones()
        }
        .harnessFilterChipButtonStyle(isSelected: false)
        .harnessNativeFormControl()
        .accessibilityValue(filters.tones.isEmpty ? "current default" : "clears level filters")

        ForEach(quickTones, id: \.rawValue) { tone in
          Button {
            filters.toggleTone(tone)
          } label: {
            HStack(spacing: 6) {
              Text(tone.label)
              Text("\(inventory.count(for: tone))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            .scaledFont(.caption.weight(.semibold))
          }
          .harnessFilterChipButtonStyle(isSelected: filters.tones.contains(tone))
          .harnessNativeFormControl()
          .accessibilityValue(filters.tones.contains(tone) ? "selected" : "not selected")
        }
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
