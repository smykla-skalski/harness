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
    for option in inventory.decisionSeverities where filters.decisionSeverities.contains(option.id) {
      chips.append(.decisionSeverity(option))
    }
    for option in inventory.semanticProperties {
      guard
        filters.semanticProperties.contains(
          SessionTimelineSemanticProperty(rawValue: option.id) ?? .toolCall
        )
      else {
        continue
      }
      chips.append(.semanticProperty(option))
    }
    for option in inventory.rawPayloadKeys where filters.rawPayloadKeys.contains(option.id) {
      chips.append(.rawField(option))
    }
    return chips
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      searchControls

      if !quickTones.isEmpty {
        toneChipsSection
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
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingXS) {
      TextField("Find in timeline", text: $filters.query)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("Search timeline")
        .accessibilityIdentifier(HarnessMonitorAccessibility.sessionTimelineFilterSearch)

      scopeMenu
      moreFiltersButton
      clearFiltersButton
    }
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
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
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
    Button("Filters", systemImage: filters.activeAdvancedFilterCount > 0
      ? "line.3.horizontal.decrease.circle.fill"
      : "line.3.horizontal.decrease.circle")
    {
      showsAdvancedFilters = true
    }
    .harnessActionButtonStyle(
      variant: .bordered,
      tint: filters.activeAdvancedFilterCount > 0 ? nil : .secondary
    )
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
    .disabled(filters.isEmpty)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionTimelineFilterClearButton)
  }

  private var toneChipsSection: some View {
    HarnessMonitorWrapLayout(
      spacing: HarnessMonitorTheme.spacingXS,
      lineSpacing: HarnessMonitorTheme.spacingXS
    ) {
      Button("All levels") {
        filters.clearTones()
      }
      .harnessFilterChipButtonStyle(isSelected: false)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
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
        .controlSize(HarnessMonitorControlMetrics.compactControlSize)
        .accessibilityValue(filters.tones.contains(tone) ? "selected" : "not selected")
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
          .controlSize(HarnessMonitorControlMetrics.compactControlSize)
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
}

private enum SessionTimelineActiveFilterChip: Identifiable {
  case eventType(SessionTimelineFacetOption)
  case agent(SessionTimelineFacetOption)
  case task(SessionTimelineFacetOption)
  case decisionSeverity(SessionTimelineFacetOption)
  case semanticProperty(SessionTimelineFacetOption)
  case rawField(SessionTimelineFacetOption)

  var id: String {
    switch self {
    case .eventType(let option):
      "type:\(option.id)"
    case .agent(let option):
      "agent:\(option.id)"
    case .task(let option):
      "task:\(option.id)"
    case .decisionSeverity(let option):
      "severity:\(option.id)"
    case .semanticProperty(let option):
      "semantic:\(option.id)"
    case .rawField(let option):
      "field:\(option.id)"
    }
  }

  var label: String {
    switch self {
    case .eventType(let option):
      "Type: \(option.label)"
    case .agent(let option):
      "Agent: \(option.label)"
    case .task(let option):
      "Task: \(option.label)"
    case .decisionSeverity(let option):
      "Decision: \(option.label)"
    case .semanticProperty(let option):
      "Data: \(option.label)"
    case .rawField(let option):
      "Field: \(option.label)"
    }
  }

  func remove(from filters: inout SessionTimelineFilterState) {
    switch self {
    case .eventType(let option):
      filters.toggleEventType(option.id)
    case .agent(let option):
      filters.toggleAgent(option.id)
    case .task(let option):
      filters.toggleTask(option.id)
    case .decisionSeverity(let option):
      if let severity = DecisionSeverity(rawValue: option.id) {
        filters.toggleDecisionSeverity(severity)
      }
    case .semanticProperty(let option):
      if let property = SessionTimelineSemanticProperty(rawValue: option.id) {
        filters.toggleSemanticProperty(property)
      }
    case .rawField(let option):
      filters.toggleRawPayloadKey(option.id)
    }
  }
}

private struct SessionTimelineAdvancedFiltersPopover: View {
  @Binding var filters: SessionTimelineFilterState
  let inventory: SessionTimelineFilterInventory

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
          Text("Filters")
            .scaledFont(.headline)
            .accessibilityAddTraits(.isHeader)
          Text("Narrow the timeline with event details and related data.")
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
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
      inventory.toneCounts.keys.contains(tone) || filters.tones.contains(tone)
    }
    if !options.isEmpty {
      facetSection(title: "Event level") {
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
        title: "Event type",
        options: inventory.eventTypes,
        selected: filters.eventTypes,
        toggle: { filters.toggleEventType($0) }
      )
    }
  }

  @ViewBuilder private var agentSection: some View {
    if !inventory.agents.isEmpty {
      stringFacetSection(
        title: "Agent",
        options: inventory.agents,
        selected: filters.agents,
        toggle: { filters.toggleAgent($0) }
      )
    }
  }

  @ViewBuilder private var taskSection: some View {
    if !inventory.tasks.isEmpty {
      stringFacetSection(
        title: "Task",
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
      facetSection(title: "Related data") {
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
        title: "Raw fields",
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
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
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
