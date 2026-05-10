import HarnessMonitorKit
import SwiftUI

enum SessionTimelineActiveFilterChip: Identifiable {
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

struct SessionTimelineAdvancedFiltersPopover: View {
  @Binding var filters: SessionTimelineFilterState
  let inventory: SessionTimelineFilterInventory
  @Environment(\.fontScale)
  private var fontScale

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
        HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
          Text("Filters")
            .scaledFont(.headline)
            .accessibilityAddTraits(.isHeader)
          Spacer(minLength: HarnessMonitorTheme.spacingLG)
          Button("Clear") {
            filters.clear()
          }
          .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
          .harnessNativeFormControl()
          .disabled(filters.isEmpty)
          .accessibilityLabel("Clear filters")
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
    .frame(
      minWidth: 360 * popoverScale,
      idealWidth: 400 * popoverScale,
      maxWidth: 460 * popoverScale,
      minHeight: 280 * popoverScale,
      idealHeight: 420 * popoverScale
    )
  }

  private var popoverScale: CGFloat {
    max(1, min(fontScale, 1.2))
  }

  private func facetGrid<Content: View>(
    @ViewBuilder content: () -> Content
  ) -> some View {
    LazyVGrid(
      columns: facetColumns,
      alignment: .leading,
      spacing: HarnessMonitorTheme.spacingXS
    ) {
      content()
    }
  }

  @ViewBuilder private var toneSection: some View {
    let options = SessionTimelineTone.allCases.filter { tone in
      inventory.toneCounts.keys.contains(tone) || filters.tones.contains(tone)
    }
    if !options.isEmpty {
      facetSection(title: "Event level") {
        facetGrid {
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
        facetGrid {
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
        facetGrid {
          ForEach(inventory.semanticProperties) { option in
            let isSelected = containsSemanticProperty(optionID: option.id)
            facetChip(
              label: option.label,
              count: option.count,
              isSelected: isSelected
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
    [
      GridItem(
        .adaptive(minimum: 140 * popoverScale, maximum: 220 * popoverScale),
        spacing: HarnessMonitorTheme.spacingXS
      )
    ]
  }

  private func stringFacetSection(
    title: String,
    options: [SessionTimelineFacetOption],
    selected: Set<String>,
    toggle: @escaping (String) -> Void
  ) -> some View {
    facetSection(title: title) {
      facetGrid {
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
    .harnessNativeFormControl()
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

  private func containsSemanticProperty(optionID: String) -> Bool {
    guard let property = SessionTimelineSemanticProperty(rawValue: optionID) else {
      return false
    }
    return filters.semanticProperties.contains(property)
  }
}
