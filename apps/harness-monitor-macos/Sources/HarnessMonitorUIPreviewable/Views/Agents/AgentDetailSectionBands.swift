import HarnessMonitorKit
import SwiftUI

struct AgentDetailSummaryBand: View {
  let store: HarnessMonitorStore
  let title: String
  let runtimeLabel: String
  let status: AgentStatus
  let roleTitle: String
  let currentTaskTitle: String
  let overviewFacts: [AgentDetailFact]
  let runtimeState: AcpAgentRuntimeState?
  let inspectStatus: AcpRuntimeInspectStatus?
  let runtimePresentation: AcpRuntimePresentation

  var body: some View {
    AgentDetailPanel {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        AgentDetailSummaryHeader(
          title: title,
          runtimeLabel: runtimeLabel,
          status: status,
          roleTitle: roleTitle,
          currentTaskTitle: currentTaskTitle,
          overviewFacts: overviewFacts
        )
        if let runtimeState, let inspectStatus {
          AcpRuntimeView(
            store: store,
            runtimeState: runtimeState,
            inspectStatus: inspectStatus,
            presentation: runtimePresentation
          )
        } else {
          AgentDetailRestingRuntimeLine(lastActivity: lastActivityFactValue)
        }
      }
    }
  }

  private var lastActivityFactValue: String {
    overviewFacts.first(where: { $0.title == "Last Activity" })?.value ?? "unknown"
  }
}

struct AgentDetailActivityBand: View {
  let store: HarnessMonitorStore
  let agentID: String
  let timeline: [TimelineEntry]
  let runtimeLaneFacts: [AgentDetailFact]
  let capabilityValues: [String]
  let hookPoints: [HookIntegrationDescriptor]
  let activityFacts: [AgentDetailFact]
  let recentToolValues: [String]
  let persona: AgentPersona?
  let assignedTasks: [WorkItem]
  let prefersWideLayout: Bool
  let isSparseState: Bool

  var body: some View {
    AgentDetailPanel(title: timeline.isEmpty ? nil : "Activity") {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          if !timeline.isEmpty {
            AgentDetailSubsectionTitle(title: "Recent transcript")
          }
          AgentTranscriptRows(
            agentID: agentID,
            timeline: timeline,
            store: store
          )
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier(HarnessMonitorAccessibility.workspaceDetailTimeline)
        }

        Divider()

        if prefersWideLayout {
          ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
              runtimeLanePane
                .frame(maxWidth: .infinity, alignment: .leading)
              assignmentPane
                .frame(maxWidth: isSparseState ? 248 : 232, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
              runtimeLanePane
              assignmentPane
            }
          }
        } else {
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
            runtimeLanePane
            assignmentPane
          }
        }
      }
    }
  }

  private var runtimeLanePane: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      AgentDetailFactInlineRow(
        title: "Runtime lane",
        facts: runtimeLaneFacts
      )
      if !activityFacts.isEmpty || !recentToolValues.isEmpty {
        AgentDetailFactInlineRow(
          title: "Recent activity",
          facts: activityFacts,
          trailingDescription: recentToolValues.isEmpty
            ? nil
            : "Recent: " + recentToolValues.joined(separator: " · ")
        )
      }
      AgentDetailReferenceDisclosure(
        agentID: agentID,
        capabilityValues: capabilityValues,
        hookPoints: hookPoints
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var assignmentPane: some View {
    AgentDetailInsetGroup(title: isSparseState ? "Current state" : "Assignment") {
      if isSparseState {
        AgentDetailOperationalSummary(
          title: "Waiting for work",
          summary: "No transcript or assignment is attached to this agent yet.",
          nextStep: "Send an update below to give the agent a concrete next step."
        )
      } else {
        AgentDetailAssignmentSection(
          persona: persona,
          assignedTasks: assignedTasks
        )
        .accessibilityElement(children: .contain)
      }
    }
  }
}

struct AgentDetailActionBand: View {
  let store: HarnessMonitorStore
  let sessionID: String
  let agentID: String
  let isLeader: Bool
  let roleActionsAvailable: Bool
  let rolePickerValues: [SessionRole]

  @Binding var rolePickerSelection: SessionRole
  @Binding var selectedSendAction: SendUpdateAction
  @Binding var signalCommand: String
  @Binding var signalMessage: String
  @Binding var signalActionHint: String
  let prefersWideLayout: Bool

  var body: some View {
    AgentDetailPanel(title: "Actions") {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        if prefersWideLayout {
          ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
              roleActionsPane
                .frame(maxWidth: roleActionsColumnWidth, alignment: .leading)
              sendUpdatePane
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
              roleActionsPane
              sendUpdatePane
            }
          }
        } else {
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
            roleActionsPane
            sendUpdatePane
          }
        }
      }
    }
  }

  private var roleActionsPane: some View {
    AgentDetailInsetGroup(title: "Role actions") {
      AgentDetailRoleActionsSection(
        store: store,
        sessionID: sessionID,
        agentID: agentID,
        isLeader: isLeader,
        roleActionsAvailable: roleActionsAvailable,
        rolePickerValues: rolePickerValues,
        rolePickerSelection: $rolePickerSelection
      )
    }
  }

  private var roleActionsColumnWidth: CGFloat {
    roleActionsAvailable && !isLeader ? 216 : 204
  }

  private var sendUpdatePane: some View {
    AgentDetailInsetGroup(title: "Send update") {
      AgentDetailSendUpdateSection(
        store: store,
        sessionID: sessionID,
        agentID: agentID,
        selectedSendAction: $selectedSendAction,
        signalCommand: $signalCommand,
        signalMessage: $signalMessage,
        signalActionHint: $signalActionHint
      )
    }
  }
}

private struct AgentDetailPanel<Content: View>: View {
  let title: String?
  private let content: Content

  init(
    title: String? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      if let title {
        Text(title)
          .scaledFont(.system(.callout, design: .rounded, weight: .semibold))
          .foregroundStyle(HarnessMonitorTheme.ink)
          .accessibilityAddTraits(.isHeader)
      }
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct AgentDetailInsetGroup<Content: View>: View {
  let title: String
  private let content: Content

  init(
    title: String,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      AgentDetailSubsectionTitle(title: title)
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct AgentDetailSummaryHeader: View {
  let title: String
  let runtimeLabel: String
  let status: AgentStatus
  let roleTitle: String
  let currentTaskTitle: String
  let overviewFacts: [AgentDetailFact]

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(title)
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .foregroundStyle(HarnessMonitorTheme.ink)
        .accessibilityAddTraits(.isHeader)
        .frame(maxWidth: .infinity, alignment: .leading)

      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingMD) {
        statusChip
        runtimeChip
        roleChip
        Spacer(minLength: 0)
      }
      .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text("Current Task")
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .accessibilityAddTraits(.isHeader)
        Text(currentTaskTitle)
          .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
          .fixedSize(horizontal: false, vertical: true)
      }

      if !overviewFacts.isEmpty {
        AgentDetailHeaderFactStrip(facts: overviewFacts)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var statusChip: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      Image(systemName: statusSymbol)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(agentStatusColor(for: status))
        .accessibilityHidden(true)
      Text(status.title)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(agentStatusColor(for: status))
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Status")
    .accessibilityValue(status.title)
  }

  private var runtimeChip: some View {
    Text(runtimeLabel)
      .scaledFont(.system(.subheadline, design: .rounded, weight: .medium))
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .lineLimit(1)
      .truncationMode(.tail)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Runtime")
      .accessibilityValue(runtimeLabel)
  }

  private var roleChip: some View {
    Text(roleTitle)
      .scaledFont(.system(.subheadline, design: .rounded, weight: .medium))
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .lineLimit(1)
      .truncationMode(.tail)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Role")
      .accessibilityValue(roleTitle)
  }

  private var statusSymbol: String {
    switch status {
    case .active:
      "checkmark.circle.fill"
    case .awaitingReview:
      "eye.circle.fill"
    case .idle:
      "pause.circle.fill"
    case .disconnected:
      "bolt.horizontal.circle.fill"
    case .removed:
      "minus.circle.fill"
    }
  }
}

private struct AgentDetailOperationalSummary: View {
  let title: String
  let summary: String
  let nextStep: String

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(title)
        .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
      Text(summary)
        .scaledFont(.subheadline)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
      Text(nextStep)
        .scaledFont(.footnote.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
