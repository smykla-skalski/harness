import HarnessMonitorKit
import SwiftUI

struct SessionTimelineFilterControls: View {
  @Binding private var filters: SessionTimelineFilterState
  private let inventory: SessionTimelineFilterInventory
  private let summary: SessionTimelineFilterSummary

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
      inventory.count(for: tone) > 0 || filters.tones.contains(tone)
    }
  }

  private var filterButtonTitle: String {
    if filters.isEmpty {
      return "More filters"
    }
    return "More filters (\(filters.activeFilterCount))"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingXS) {
        TextField("Search timeline", text: $filters.query)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier(HarnessMonitorAccessibility.sessionTimelineFilterSearch)

        scopeMenu
        moreFiltersButton

        if !filters.isEmpty {
          clearFiltersButton
        }
      }

      if !quickTones.isEmpty {
        toneChips
      }

      if !summary.statusText.isEmpty {
        Text(summary.statusText)
          .scaledFont(.caption.monospaced())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .accessibilityLabel(summary.accessibilityText)
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

  private var scopeMenu: some View {
    Menu {
      Picker("Search scope", selection: $filters.searchScope) {
        ForEach(SessionTimelineSearchScope.allCases) { scope in
          Label(scope.label, systemImage: scope.systemImage)
            .tag(scope)
        }
      }
    } label: {
      Image(systemName: filters.searchScope.systemImage)
        .imageScale(.medium)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel("Timeline search scope — \(filters.searchScope.label)")
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionTimelineFilterScopeMenu)
  }

  private var moreFiltersButton: some View {
    Button(filterButtonTitle, systemImage: filters.isEmpty
      ? "line.3.horizontal.decrease.circle"
      : "line.3.horizontal.decrease.circle.fill")
    {
      showsAdvancedFilters = true
    }
    .harnessActionButtonStyle(variant: .bordered, tint: filters.isEmpty ? .secondary : nil)
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
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
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionTimelineFilterClearButton)
  }

  private var toneChips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        Button("All levels") {
          filters.clearTones()
        }
        .harnessFilterChipButtonStyle(isSelected: filters.tones.isEmpty)

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
          .accessibilityValue(filters.tones.contains(tone) ? "selected" : "not selected")
        }
      }
      .fixedSize(horizontal: true, vertical: false)
      .padding(.vertical, 1)
    }
    .scrollClipDisabled()
  }
}

private struct SessionTimelineAdvancedFiltersPopover: View {
  @Binding var filters: SessionTimelineFilterState
  let inventory: SessionTimelineFilterInventory

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
        toneSection
        eventTypeSection
        agentSection
        taskSection
        decisionSeveritySection
        semanticPropertiesSection
        rawPayloadKeysSection
      }
      .padding(HarnessMonitorTheme.spacingLG)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minWidth: 360, idealWidth: 400, maxWidth: 440, minHeight: 280, idealHeight: 420)
  }

  @ViewBuilder private var toneSection: some View {
    let options = SessionTimelineTone.allCases.filter { tone in
      inventory.count(for: tone) > 0 || filters.tones.contains(tone)
    }
    if !options.isEmpty {
      facetSection(title: "Levels") {
        LazyVGrid(columns: facetColumns, alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
          ForEach(options, id: \.rawValue) { tone in
            facetChip(
              label: tone.label,
              count: inventory.count(for: tone),
              isSelected: filters.tones.contains(tone)
            ) {
              filters.toggleTone(tone)
            }
          }
        }
      }
    }
  }

  @ViewBuilder private var eventTypeSection: some View {
    if !inventory.eventTypes.isEmpty {
      stringFacetSection(
        title: "Event types",
        options: inventory.eventTypes,
        selected: filters.eventTypes,
        toggle: { filters.toggleEventType($0) }
      )
    }
  }

  @ViewBuilder private var agentSection: some View {
    if !inventory.agents.isEmpty {
      stringFacetSection(
        title: "Agents / sources",
        options: inventory.agents,
        selected: filters.agents,
        toggle: { filters.toggleAgent($0) }
      )
    }
  }

  @ViewBuilder private var taskSection: some View {
    if !inventory.tasks.isEmpty {
      stringFacetSection(
        title: "Tasks",
        options: inventory.tasks,
        selected: filters.tasks,
        toggle: { filters.toggleTask($0) }
      )
    }
  }

  @ViewBuilder private var decisionSeveritySection: some View {
    if !inventory.decisionSeverities.isEmpty {
      facetSection(title: "Decision severity") {
        LazyVGrid(columns: facetColumns, alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
          ForEach(inventory.decisionSeverities) { option in
            facetChip(
              label: option.label,
              count: option.count,
              isSelected: filters.decisionSeverities.contains(option.id)
            ) {
              if let severity = DecisionSeverity(rawValue: option.id) {
                filters.toggleDecisionSeverity(severity)
              }
            }
          }
        }
      }
    }
  }

  @ViewBuilder private var semanticPropertiesSection: some View {
    if !inventory.semanticProperties.isEmpty {
      facetSection(title: "Semantic properties") {
        LazyVGrid(columns: facetColumns, alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
          ForEach(inventory.semanticProperties) { option in
            facetChip(
              label: option.label,
              count: option.count,
              isSelected: filters.semanticProperties.contains(
                SessionTimelineSemanticProperty(rawValue: option.id) ?? .toolCall
              )
            ) {
              guard let property = SessionTimelineSemanticProperty(rawValue: option.id) else {
                return
              }
              filters.toggleSemanticProperty(property)
            }
          }
        }
      }
    }
  }

  @ViewBuilder private var rawPayloadKeysSection: some View {
    if !inventory.rawPayloadKeys.isEmpty {
      stringFacetSection(
        title: "Raw payload keys",
        options: inventory.rawPayloadKeys,
        selected: filters.rawPayloadKeys,
        toggle: { filters.toggleRawPayloadKey($0) }
      )
    }
  }

  private var facetColumns: [GridItem] {
    [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: HarnessMonitorTheme.spacingXS)]
  }

  private func stringFacetSection(
    title: String,
    options: [SessionTimelineFacetOption],
    selected: Set<String>,
    toggle: @escaping (String) -> Void
  ) -> some View {
    facetSection(title: title) {
      LazyVGrid(columns: facetColumns, alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        ForEach(options) { option in
          facetChip(
            label: option.label,
            count: option.count,
            isSelected: selected.contains(option.id)
          ) {
            toggle(option.id)
          }
        }
      }
    }
  }

  private func facetChip(
    label: String,
    count: Int,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Text(label)
          .lineLimit(1)
          .truncationMode(.tail)
        Text("\(count)")
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .scaledFont(.caption.weight(.semibold))
    }
    .harnessFilterChipButtonStyle(isSelected: isSelected)
    .accessibilityValue(isSelected ? "selected" : "not selected")
  }

  private func facetSection<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(title)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      content()
    }
  }
}
