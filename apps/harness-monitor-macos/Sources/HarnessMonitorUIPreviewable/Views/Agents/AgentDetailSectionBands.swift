import HarnessMonitorKit
import SwiftUI

struct AgentDetailSummaryBand: View {
  let store: HarnessMonitorStore
  let title: String
  let runtimeLabel: String
  let status: AgentStatus
  let statusLabel: String
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
          statusLabel: statusLabel,
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

  var lastActivityFactValue: String {
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
  // Replaces ViewThatFits: a single deterministic if/else gated on a measured
  // container width avoids the double-tree-build cost on every body update.
  @State var fitsHorizontally = true

  var horizontalMinWidth: CGFloat {
    isSparseState ? 544 : 528
  }

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
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentDetailTimeline)
        }

        Divider()

        if prefersWideLayout && fitsHorizontally {
          HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
            runtimeLanePane
              .frame(maxWidth: .infinity, alignment: .leading)
            assignmentPane
              .frame(maxWidth: isSparseState ? 248 : 232, alignment: .leading)
          }
        } else {
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
            runtimeLanePane
            assignmentPane
          }
        }
      }
    }
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      let next = width >= horizontalMinWidth
      if fitsHorizontally != next {
        fitsHorizontally = next
      }
    }
  }

  var runtimeLanePane: some View {
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

  var assignmentPane: some View {
    AgentDetailInsetGroup(title: isSparseState ? "Current state" : "Assignment") {
      if isSparseState {
        AgentDetailOperationalSummary(
          title: "Waiting for work",
          summary: "No transcript or assignment is attached to this agent yet",
          nextStep: "Send an update below to give the agent a concrete next step"
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
  let agentName: String?
  let isLeader: Bool
  let roleActionsAvailable: Bool
  let actionActorID: String?
  let actionUnavailableMessage: String?
  let rolePickerValues: [SessionRole]
  let runtimeState: AcpAgentRuntimeState?

  @Binding var rolePickerSelection: SessionRole
  @Binding var selectedSendAction: SendUpdateAction
  @Binding var signalCommand: String
  @Binding var signalMessage: String
  @Binding var signalActionHint: String
  let prefersWideLayout: Bool
  // Replaces ViewThatFits: deterministic if/else gated on measured width.
  @State var fitsHorizontally = true

  init(
    store: HarnessMonitorStore,
    sessionID: String,
    agentID: String,
    agentName: String? = nil,
    isLeader: Bool,
    roleActionsAvailable: Bool,
    actionActorID: String? = nil,
    actionUnavailableMessage: String? = nil,
    rolePickerValues: [SessionRole],
    runtimeState: AcpAgentRuntimeState? = nil,
    rolePickerSelection: Binding<SessionRole>,
    selectedSendAction: Binding<SendUpdateAction>,
    signalCommand: Binding<String>,
    signalMessage: Binding<String>,
    signalActionHint: Binding<String>,
    prefersWideLayout: Bool
  ) {
    self.store = store
    self.sessionID = sessionID
    self.agentID = agentID
    self.agentName = agentName
    self.isLeader = isLeader
    self.roleActionsAvailable = roleActionsAvailable
    self.actionActorID = actionActorID
    self.actionUnavailableMessage = actionUnavailableMessage
    self.rolePickerValues = rolePickerValues
    self.runtimeState = runtimeState
    _rolePickerSelection = rolePickerSelection
    _selectedSendAction = selectedSendAction
    _signalCommand = signalCommand
    _signalMessage = signalMessage
    _signalActionHint = signalActionHint
    self.prefersWideLayout = prefersWideLayout
  }

  var horizontalMinWidth: CGFloat {
    roleActionsColumnWidth + HarnessMonitorTheme.spacingMD + 300
  }

  var body: some View {
    AgentDetailPanel(title: "Actions") {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        if prefersWideLayout && fitsHorizontally {
          HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
            roleActionsPane
              .frame(maxWidth: roleActionsColumnWidth, alignment: .leading)
            sendUpdatePane
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        } else {
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
            roleActionsPane
            sendUpdatePane
          }
        }
      }
    }
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      let next = width >= horizontalMinWidth
      if fitsHorizontally != next {
        fitsHorizontally = next
      }
    }
  }

  var roleActionsPane: some View {
    AgentDetailInsetGroup(title: "Role actions") {
      AgentDetailRoleActionsSection(
        store: store,
        sessionID: sessionID,
        agentID: agentID,
        actionActorID: actionActorID,
        isLeader: isLeader,
        roleActionsAvailable: roleActionsAvailable,
        rolePickerValues: rolePickerValues,
        rolePickerSelection: $rolePickerSelection
      )
    }
  }

  var roleActionsColumnWidth: CGFloat {
    roleActionsAvailable && !isLeader ? 216 : 204
  }

  var sendUpdatePane: some View {
    AgentDetailInsetGroup(title: "Send update") {
      AgentDetailSendUpdateSection(
        store: store,
        sessionID: sessionID,
        agentID: agentID,
        agentName: agentName,
        actionActorID: actionActorID,
        actionUnavailableMessage: actionUnavailableMessage,
        runtimeState: runtimeState,
        selectedSendAction: $selectedSendAction,
        signalCommand: $signalCommand,
        signalMessage: $signalMessage,
        signalActionHint: $signalActionHint
      )
    }
  }
}
