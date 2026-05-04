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

struct AgentDetailRoleActionsSection: View {
  let store: HarnessMonitorStore
  let sessionID: String
  let agentID: String
  let isLeader: Bool
  let roleActionsAvailable: Bool
  let rolePickerValues: [SessionRole]

  @Binding var rolePickerSelection: SessionRole

  private var disabledReason: String {
    if isLeader {
      "Transfer leadership before changing the leader's role or removing this agent."
    } else if !roleActionsAvailable {
      "Role actions are unavailable for this session."
    } else {
      ""
    }
  }

  var body: some View {
    if !roleActionsAvailable {
      AgentDetailEmptyState(
        title: "Role actions unavailable",
        systemImage: "lock.slash",
        description: disabledReason,
        tint: HarnessMonitorTheme.caution
      )
    } else if isLeader {
      AgentDetailEmptyState(
        title: "Leader role is fixed",
        systemImage: "crown",
        description: disabledReason,
        tint: HarnessMonitorTheme.warmAccent
      )
    } else {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        AgentDetailFieldBlock(title: "Role") {
          Picker("Role", selection: $rolePickerSelection) {
            ForEach(rolePickerValues, id: \.self) { role in
              Text(role.title).tag(role)
            }
          }
          .labelsHidden()
          .harnessNativeFormControl()
          .accessibilityLabel("Role")
          .accessibilityIdentifier(HarnessMonitorAccessibility.workspaceDetailRolePicker)
        }
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          HarnessInlineActionButton(
            title: "Change Role",
            actionID: .changeRole(sessionID: sessionID, agentID: agentID),
            store: store,
            variant: .prominent,
            tint: nil,
            isExternallyDisabled: false,
            accessibilityIdentifier: HarnessMonitorAccessibility.workspaceDetailRoleChange,
            action: {
              Task {
                _ = await store.changeRole(agentID: agentID, role: rolePickerSelection)
              }
            }
          )
          HarnessInlineActionButton(
            title: "Remove Agent",
            actionID: .removeAgent(sessionID: sessionID, agentID: agentID),
            store: store,
            variant: .bordered,
            tint: .red,
            isExternallyDisabled: false,
            accessibilityIdentifier: HarnessMonitorAccessibility.workspaceDetailRoleRemove,
            action: { store.requestRemoveAgentConfirmation(agentID: agentID) }
          )
        }
      }
    }
  }
}

struct AgentDetailSendUpdateSection: View {
  let store: HarnessMonitorStore
  let sessionID: String
  let agentID: String

  @Binding var selectedSendAction: SendUpdateAction
  @Binding var signalCommand: String
  @Binding var signalMessage: String
  @Binding var signalActionHint: String

  private var trimmedCommand: String {
    signalCommand.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var trimmedMessage: String {
    signalMessage.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var disabledReason: String? {
    if store.isSessionReadOnly {
      return "Session is read-only."
    }
    if trimmedCommand.isEmpty {
      return "Pick or type an update type."
    }
    if trimmedMessage.isEmpty {
      return "Type a message to send."
    }
    return nil
  }

  private var trimmedActionHint: String? {
    let trimmed = signalActionHint.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  var body: some View {
    if store.isSessionReadOnly {
      AgentDetailEmptyState(
        title: "Updates unavailable",
        systemImage: "lock.fill",
        description: "This session is read-only, so messages cannot be sent to the agent.",
        tint: HarnessMonitorTheme.secondaryInk
      )
    } else {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        AgentDetailFieldBlock(title: "Update type") {
          Picker("Update type", selection: $selectedSendAction) {
            ForEach(SendUpdateAction.allLabeledCases, id: \.self) { action in
              Text(action.humanLabel).tag(action)
            }
          }
          .labelsHidden()
          .harnessNativeFormControl()
          .accessibilityLabel("Update type")
          .accessibilityIdentifier(HarnessMonitorAccessibility.workspaceDetailSignalCommand)
        }
        if selectedSendAction == .custom {
          AgentDetailFieldBlock(title: "Custom update type") {
            TextField("Custom update type", text: $signalCommand)
              .harnessNativeFormControl()
              .submitLabel(.send)
              .accessibilityLabel("Custom update type")
          }
        }
        AgentDetailFieldBlock(title: "Message") {
          TextField("Tell this agent what to do next", text: $signalMessage, axis: .vertical)
            .harnessNativeFormControl()
            .lineLimit(2, reservesSpace: true)
            .accessibilityIdentifier(HarnessMonitorAccessibility.workspaceDetailSignalMessage)
            .accessibilityLabel("Message")
            .submitLabel(.send)
        }
        AgentDetailFieldBlock(
          title: "Optional context",
          help: "Add extra framing only if it helps the agent act on the update."
        ) {
          TextField(
            "Constraints, acceptance criteria, or related context",
            text: $signalActionHint
          )
          .harnessNativeFormControl()
          .accessibilityIdentifier(HarnessMonitorAccessibility.workspaceDetailSignalAction)
          .accessibilityLabel("Optional context")
          .submitLabel(.send)
        }
        VStack(alignment: .trailing, spacing: HarnessMonitorTheme.spacingSM) {
          HarnessInlineActionButton(
            title: "Send Update",
            actionID: .sendSignal(sessionID: sessionID, agentID: agentID),
            store: store,
            variant: .prominent,
            tint: nil,
            isExternallyDisabled: disabledReason != nil,
            accessibilityIdentifier: HarnessMonitorAccessibility.workspaceDetailSignalSend,
            action: {
              Task {
                await store.sendSignal(
                  agentID: agentID,
                  command: trimmedCommand,
                  message: trimmedMessage,
                  actionHint: trimmedActionHint
                )
              }
            }
          )
          .accessibilityHint(disabledReason ?? "")
          if let disabledReason {
            Text(disabledReason)
              .scaledFont(.caption)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
  }
}
