import HarnessMonitorKit
import SwiftUI

struct AgentDetailFact: Identifiable {
  let title: String
  let value: String
  let tint: Color?
  let hidesWhenZero: Bool

  var id: String { title }

  init(
    title: String,
    value: String,
    tint: Color? = nil,
    hidesWhenZero: Bool = false
  ) {
    self.title = title
    self.value = value
    self.tint = tint
    self.hidesWhenZero = hidesWhenZero
  }

  var isHiddenZero: Bool {
    hidesWhenZero && value.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
  }
}

struct AgentDetailFactSummaryGrid: View {
  let facts: [AgentDetailFact]
  let maximumColumns: Int

  init(facts: [AgentDetailFact], maximumColumns: Int = 2) {
    self.facts = facts
    self.maximumColumns = maximumColumns
  }

  private var visibleFacts: [AgentDetailFact] {
    facts.filter { !$0.isHiddenZero }
  }

  var body: some View {
    HarnessMonitorAdaptiveGridLayout(
      minimumColumnWidth: 160,
      maximumColumns: maximumColumns,
      spacing: HarnessMonitorTheme.spacingSM
    ) {
      ForEach(visibleFacts) { fact in
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
          Text(fact.title)
            .scaledFont(.caption.bold())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          Text(fact.value)
            .scaledFont(.system(.body, design: .rounded, weight: .semibold))
            .foregroundStyle(fact.tint ?? HarnessMonitorTheme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, HarnessMonitorTheme.spacingXS)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(fact.title)
        .accessibilityValue(fact.value)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct AgentDetailSubsectionTitle: View {
  let title: String

  var body: some View {
    Text(title)
      .scaledFont(.caption.bold())
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .accessibilityAddTraits(.isHeader)
  }
}

struct AgentDetailMetadataSection: View {
  let title: String
  let values: [String]
  let summaryFacts: [AgentDetailFact]
  let inlineValues: Bool

  init(
    title: String,
    values: [String],
    summaryFacts: [AgentDetailFact] = [],
    inlineValues: Bool = false
  ) {
    self.title = title
    self.values = values
    self.summaryFacts = summaryFacts
    self.inlineValues = inlineValues
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      AgentDetailSubsectionTitle(title: title)
      if !summaryFacts.isEmpty {
        AgentDetailFactSummaryGrid(facts: summaryFacts)
      }
      if !values.isEmpty {
        if inlineValues {
          Text(values.joined(separator: " · "))
            .scaledFont(.subheadline)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Recent tools")
            .accessibilityValue(values.joined(separator: ", "))
        } else {
          AgentDetailMetadataList(values: values)
        }
      }
    }
  }
}

struct AgentDetailMetadataList: View {
  let values: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      ForEach(Array(values.enumerated()), id: \.offset) { _, value in
        Text(value)
          .scaledFont(.subheadline)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct AgentDetailHookPointsGrid: View {
  let hookPoints: [HookIntegrationDescriptor]

  private static let columnHeaderTrigger = "Trigger"
  private static let columnHeaderLatency = "Latency"
  private static let columnHeaderContext = "Context"

  var body: some View {
    if hookPoints.isEmpty {
      EmptyView()
    } else {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        headerRow
        ForEach(hookPoints) { hook in
          row(for: hook)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Hook points")
    }
  }

  private var headerRow: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      cell(Self.columnHeaderTrigger, weight: .semibold, isHeader: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      cell(Self.columnHeaderLatency, weight: .semibold, isHeader: true)
        .frame(width: 64, alignment: .trailing)
      cell(Self.columnHeaderContext, weight: .semibold, isHeader: true)
        .frame(width: 80, alignment: .trailing)
    }
    .accessibilityHidden(true)
  }

  private func row(for hook: HookIntegrationDescriptor) -> some View {
    let trigger = Self.humanizedTrigger(for: hook)
    let latency = "\(hook.typicalLatencySeconds)s"
    let context = hook.supportsContextInjection ? "On" : "Off"
    return HStack(spacing: HarnessMonitorTheme.spacingSM) {
      cell(trigger, weight: .regular, isHeader: false)
        .frame(maxWidth: .infinity, alignment: .leading)
      cell(latency, weight: .medium, isHeader: false)
        .frame(width: 64, alignment: .trailing)
      cell(context, weight: .medium, isHeader: false)
        .frame(width: 80, alignment: .trailing)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(trigger)
    .accessibilityValue("\(latency), context \(context)")
  }

  private func cell(_ text: String, weight: Font.Weight, isHeader: Bool) -> some View {
    Text(text)
      .scaledFont(.caption.weight(weight))
      .foregroundStyle(
        isHeader ? HarnessMonitorTheme.secondaryInk : HarnessMonitorTheme.ink
      )
      .lineLimit(1)
      .truncationMode(.tail)
  }

  nonisolated static func humanizedTrigger(for hook: HookIntegrationDescriptor) -> String {
    switch hook.name {
    case "BeforeTool":
      "Before each tool call"
    case "AfterTool":
      "After each tool call"
    case "BeforePrompt":
      "Before each prompt"
    case "AfterPrompt":
      "After each prompt"
    default:
      hook.name
    }
  }
}

struct AgentDetailFieldBlock<Content: View>: View {
  let title: String
  let help: String?
  private let content: Content

  init(
    title: String,
    help: String? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.help = help
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(title)
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      content
      if let help {
        Text(help)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

struct AgentDetailEmptyState: View {
  let title: String
  let systemImage: String
  let description: String
  let nextStep: String?
  let tint: Color

  init(
    title: String,
    systemImage: String,
    description: String,
    nextStep: String? = nil,
    tint: Color
  ) {
    self.title = title
    self.systemImage = systemImage
    self.description = description
    self.nextStep = nextStep
    self.tint = tint
  }

  var body: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: systemImage)
        .scaledFont(.callout.weight(.semibold))
        .foregroundStyle(tint)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text(title)
          .scaledFont(.callout.weight(.semibold))
        Text(description)
          .scaledFont(.footnote)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
        if let nextStep {
          Text(nextStep)
            .scaledFont(.footnote.weight(.semibold))
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, HarnessMonitorTheme.spacingXS)
        }
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

struct AgentDetailAssignmentSection: View {
  let persona: AgentPersona?
  let assignedTasks: [WorkItem]

  var body: some View {
    if persona == nil && assignedTasks.isEmpty {
      AgentDetailEmptyState(
        title: "No assignment yet",
        systemImage: "person.2.slash",
        description: "This agent does not currently carry a persona or a task assignment.",
        nextStep: "Send an update below or assign a task from the workspace board.",
        tint: HarnessMonitorTheme.secondaryInk
      )
      .accessibilityIdentifier(HarnessMonitorAccessibility.workspaceDetailPersona)
    } else {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        if let persona {
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
            AgentDetailSubsectionTitle(title: "Persona")
            VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
              Text(persona.name)
                .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
              Text(persona.description)
                .scaledFont(.subheadline)
                .foregroundStyle(HarnessMonitorTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          .accessibilityIdentifier(HarnessMonitorAccessibility.workspaceDetailPersona)
        }
        if !assignedTasks.isEmpty {
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
            AgentDetailSubsectionTitle(title: "Assigned tasks")
            VStack(spacing: 0) {
              ForEach(Array(assignedTasks.enumerated()), id: \.element.id) { index, task in
                HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
                  Text(task.title)
                    .scaledFont(.system(.subheadline, design: .rounded, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                  Spacer(minLength: HarnessMonitorTheme.spacingSM)
                  Text(task.status.title)
                    .scaledFont(.caption)
                    .foregroundStyle(taskStatusColor(for: task.status))
                    .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, HarnessMonitorTheme.spacingMD)
                .padding(.vertical, HarnessMonitorTheme.spacingSM)
                .accessibilityElement(children: .combine)
                if index < assignedTasks.count - 1 {
                  Divider()
                }
              }
            }
          }
          .accessibilityIdentifier(HarnessMonitorAccessibility.workspaceDetailAssignedTasks)
        }
      }
    }
  }
}
