import HarnessMonitorKit
import SwiftUI

struct AgentDetailFact: Identifiable {
  let title: String
  let value: String
  let tint: Color?

  var id: String { title }

  init(title: String, value: String, tint: Color? = nil) {
    self.title = title
    self.value = value
    self.tint = tint
  }
}

struct AgentDetailFactSummaryGrid: View {
  let facts: [AgentDetailFact]
  let maximumColumns: Int

  init(facts: [AgentDetailFact], maximumColumns: Int = 2) {
    self.facts = facts
    self.maximumColumns = maximumColumns
  }

  var body: some View {
    HarnessMonitorAdaptiveGridLayout(
      minimumColumnWidth: 160,
      maximumColumns: maximumColumns,
      spacing: HarnessMonitorTheme.spacingSM
    ) {
      ForEach(facts) { fact in
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

  init(title: String, values: [String], summaryFacts: [AgentDetailFact] = []) {
    self.title = title
    self.values = values
    self.summaryFacts = summaryFacts
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      AgentDetailSubsectionTitle(title: title)
      if !summaryFacts.isEmpty {
        AgentDetailFactSummaryGrid(facts: summaryFacts)
      }
      if !values.isEmpty {
        AgentDetailMetadataList(values: values)
      }
    }
  }
}

struct AgentDetailMetadataList: View {
  let values: [String]

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(values.enumerated()), id: \.offset) { index, value in
        HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
          Circle()
            .fill(HarnessMonitorTheme.tertiaryInk)
            .frame(width: 6, height: 6)
            .padding(.top, 6)
          Text(value)
            .scaledFont(.subheadline)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, HarnessMonitorTheme.spacingMD)
        .padding(.vertical, HarnessMonitorTheme.spacingSM)
        .frame(maxWidth: .infinity, alignment: .leading)
        if index < values.count - 1 {
          Divider()
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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
  let tint: Color

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
