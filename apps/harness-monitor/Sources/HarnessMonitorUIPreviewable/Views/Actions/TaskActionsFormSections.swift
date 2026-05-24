import HarnessMonitorKit
import SwiftUI

struct TaskActionsPickerSection: View {
  let task: WorkItem
  let tasks: [WorkItem]
  let assignmentAgents: [AgentRegistration]
  let taskSelection: Binding<String>
  let assigneeSelection: Binding<String>
  @Binding var taskStatus: TaskStatus
  @Binding var queuePolicy: TaskQueuePolicy

  var body: some View {
    Picker("Task", selection: taskSelection) {
      ForEach(tasks) { item in
        Text(item.title).tag(item.taskId)
      }
    }
    .harnessNativeFormControl()
    assigneePicker
    statusPicker
    Picker("Queue Policy", selection: $queuePolicy) {
      ForEach(TaskQueuePolicy.allCases, id: \.self) { policy in
        Text(policy.title).tag(policy)
      }
    }
    .harnessNativeFormControl()
  }

  @ViewBuilder private var assigneePicker: some View {
    if assignmentAgents.isEmpty {
      LabeledContent("Assignee") {
        Text("No free workers")
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
    } else {
      Picker("Assignee", selection: assigneeSelection) {
        ForEach(assignmentAgents) { agent in
          Text(agent.name).tag(agent.agentId)
        }
      }
      .harnessNativeFormControl()
    }
  }

  @ViewBuilder private var statusPicker: some View {
    if task.status.isReviewManagedStatus {
      LabeledContent("Status") {
        Text(task.status.title)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      Text("Review status changes are managed by the review flow")
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    } else {
      Picker("Status", selection: $taskStatus) {
        ForEach(TaskStatus.genericStatusChoices, id: \.self) { status in
          Text(status.title).tag(status)
        }
      }
      .harnessNativeFormControl()
    }
  }
}

struct TaskActionsAssignmentRows: View {
  let task: WorkItem
  let sessionID: String
  let store: HarnessMonitorStore
  let areSessionActionsAvailable: Bool
  let assignmentUnavailableMessage: String?
  let taskMutationUnavailableMessage: String?
  let submitAssign: HarnessMonitorActionButton.Action
  let submitUpdateQueuePolicy: HarnessMonitorActionButton.Action

  var body: some View {
    HStack {
      HarnessInlineActionButton(
        title: "Assign",
        actionID: .assignTask(sessionID: sessionID, taskID: task.taskId),
        store: store,
        variant: .prominent,
        tint: nil,
        isExternallyDisabled:
          !areSessionActionsAvailable || assignmentUnavailableMessage != nil,
        accessibilityIdentifier: HarnessMonitorAccessibility.assignTaskButton,
        help: assignmentUnavailableMessage ?? "",
        action: submitAssign
      )
      HarnessInlineActionButton(
        title: "Save Queue Policy",
        actionID: .updateTaskQueuePolicy(sessionID: sessionID, taskID: task.taskId),
        store: store,
        variant: .bordered,
        tint: .secondary,
        isExternallyDisabled:
          !areSessionActionsAvailable || taskMutationUnavailableMessage != nil,
        accessibilityIdentifier: HarnessMonitorAccessibility.updateTaskQueuePolicyButton,
        help: taskMutationUnavailableMessage ?? "",
        action: submitUpdateQueuePolicy
      )
    }
  }
}

struct TaskActionsStatusRow: View {
  let task: WorkItem
  let sessionID: String
  let store: HarnessMonitorStore
  let areSessionActionsAvailable: Bool
  let taskMutationUnavailableMessage: String?
  @Binding var statusNote: String
  let submitUpdateStatus: HarnessMonitorActionButton.Action

  var body: some View {
    if let message = taskMutationUnavailableMessage {
      Text("Status updates are unavailable while the task is in the review flow")
        .scaledFont(.footnote)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text(message)
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    } else {
      HStack {
        HarnessInlineActionButton(
          title: "Update Status",
          actionID: .updateTaskStatus(sessionID: sessionID, taskID: task.taskId),
          store: store,
          variant: .bordered,
          tint: .secondary,
          isExternallyDisabled: !areSessionActionsAvailable,
          accessibilityIdentifier: HarnessMonitorAccessibility.updateTaskStatusButton,
          action: submitUpdateStatus
        )
        TextField("Update note", text: $statusNote, axis: .vertical)
          .harnessNativeFormControl()
          .lineLimit(2, reservesSpace: true)
          .submitLabel(.done)
      }
    }
  }
}

struct TaskActionsUnavailableState: View {
  let dismiss: HarnessMonitorActionButton.Action

  var body: some View {
    VStack(spacing: HarnessMonitorTheme.spacingMD) {
      Image(systemName: "questionmark.circle")
        .font(.system(size: 36))
        .foregroundStyle(.secondary)
      Text("Task unavailable")
        .scaledFont(.headline)
      Button("Dismiss") { dismiss() }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier(HarnessMonitorAccessibility.taskActionsSheetDismiss)
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
