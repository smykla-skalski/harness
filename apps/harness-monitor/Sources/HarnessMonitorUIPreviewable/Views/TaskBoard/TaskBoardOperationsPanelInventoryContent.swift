import HarnessMonitorKit
import SwiftUI

/// Renders the operations inventory card (status filter, action buttons,
/// audit/projects/machines summary). Owns no state; receives bindings and
/// store from the parent so `TaskBoardOperationsPanel` stays under the
/// per-file line cap.
struct TaskBoardOperationsPanelInventoryCard: View {
  let store: HarnessMonitorStore
  let dashboard: HarnessMonitorStore.ContentDashboardSlice
  let metrics: TaskBoardOverviewMetrics
  @Binding var inventoryStatusChoice: TaskBoardStatusFilterChoice
  @Environment(\.fontScale)
  private var fontScale

  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }
  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    TaskBoardOperationsCard(
      title: "Audit & Inventory",
      metrics: metrics
    ) {
      statusPickerField
      actionRow
      summaryContent
    }
  }

  private var statusPickerField: some View {
    TaskBoardOperationsFormRow("Status filter") {
      Picker("", selection: $inventoryStatusChoice) {
        ForEach(TaskBoardStatusFilterChoice.stableAllCases) { choice in
          Text(choice.title).tag(choice)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .harnessNativeFormControl()
      .accessibilityLabel("Status filter")
      .accessibilityIdentifier("harness.task-board.inventory.status")
    }
  }

  private var actionRow: some View {
    TaskBoardOperationsFormRow(
      "Actions",
      contentMaxWidth: nil,
      minHeight: nil
    ) {
      HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.itemSpacing) {
        HarnessMonitorWrapLayout(
          spacing: HarnessMonitorTheme.itemSpacing,
          lineSpacing: HarnessMonitorTheme.itemSpacing,
          rowAlignment: .trailing
        ) {
          actionButtons
        }
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
  }

  @ViewBuilder private var actionButtons: some View {
    actionButton(
      title: "Audit",
      systemImage: "checkmark.shield",
      accessibilityIdentifier: "harness.task-board.audit.run",
      help: "Load board status audit counts"
    ) {
      let status = inventoryStatusChoice.status
      HarnessMonitorAsyncWorkQueue.shared.submit(
        .init(title: "Loading task board audit") {
          await store.auditTaskBoard(status: status)
        }
      )
    }
    actionButton(
      title: "Projects",
      systemImage: "folder",
      accessibilityIdentifier: "harness.task-board.projects.run",
      help: "Load task-board project summary counts"
    ) {
      let status = inventoryStatusChoice.status
      HarnessMonitorAsyncWorkQueue.shared.submit(
        .init(title: "Loading task board projects") {
          await store.refreshTaskBoardProjects(status: status)
        }
      )
    }
    actionButton(
      title: "Machines",
      systemImage: "desktopcomputer",
      accessibilityIdentifier: "harness.task-board.machines.run",
      help: "Load task-board machine summary counts"
    ) {
      let status = inventoryStatusChoice.status
      HarnessMonitorAsyncWorkQueue.shared.submit(
        .init(title: "Loading task board machines") {
          await store.refreshTaskBoardMachines(status: status)
        }
      )
    }
  }

  private func actionButton(
    title: String,
    systemImage: String,
    accessibilityIdentifier: String,
    help: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .lineLimit(1)
    }
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .harnessNativeFormControl()
    .fixedSize(horizontal: true, vertical: true)
    .disabled(
      store.isDaemonActionInFlight || store.contentUI.dashboard.connectionState != .online
    )
    .help(
      store.contentUI.dashboard.connectionState == .online
        ? help
        : "Connect to the Harness daemon to run this action"
    )
    .accessibilityIdentifier(accessibilityIdentifier)
  }

  @ViewBuilder private var summaryContent: some View {
    auditBlock
    projectsBlock
    machinesBlock
  }

  @ViewBuilder private var auditBlock: some View {
    block(title: "Audit", systemImage: "checkmark.shield") {
      if let audit = dashboard.taskBoardItemAuditSummary {
        auditPillsAndStatuses(audit)
      } else {
        placeholder("Load a task-board audit to inspect readiness and status totals")
      }
    }
  }

  @ViewBuilder
  private func auditPillsAndStatuses(_ audit: TaskBoardAuditSummary) -> some View {
    pillRow {
      TaskBoardSummaryPill(value: "\(audit.total)", label: "Total")
      TaskBoardSummaryPill(
        value: "\(audit.ready)", label: "Ready", tint: HarnessMonitorTheme.accent)
      if audit.blocked != 0 {
        TaskBoardSummaryPill(
          value: "\(audit.blocked)",
          label: "Blocked",
          tint: HarnessMonitorTheme.danger
        )
      }
      if audit.deleted != 0 {
        TaskBoardSummaryPill(value: "\(audit.deleted)", label: "Deleted")
      }
    }
    if !audit.byStatus.isEmpty {
      pillRow {
        ForEach(audit.byStatus, id: \.status.id) { count in
          TaskBoardSummaryPill(
            value: "\(count.count)",
            label: count.status.title,
            tint: taskBoardStatusColor(for: count.status)
          )
        }
      }
    }
  }

  @ViewBuilder private var projectsBlock: some View {
    block(title: "Projects", systemImage: "folder") {
      if let projects = dashboard.taskBoardProjects {
        if projects.isEmpty {
          placeholder("No matching projects")
        } else {
          ForEach(projects.prefix(5)) { project in
            row(
              title: project.projectId,
              subtitle: "\(project.readyCount) ready of \(project.itemCount) items"
            )
          }
        }
      } else {
        placeholder("Load project summaries for the current board filter")
      }
    }
  }

  @ViewBuilder private var machinesBlock: some View {
    block(title: "Machines", systemImage: "desktopcomputer") {
      if let machines = dashboard.taskBoardMachines {
        if machines.isEmpty {
          placeholder("No matching machine modes")
        } else {
          ForEach(machines.prefix(5)) { machine in
            row(
              title: machine.mode.title,
              subtitle: "\(machine.readyCount) ready of \(machine.itemCount) items"
            )
          }
        }
      } else {
        placeholder("Load machine summaries for the current board filter")
      }
    }
  }

  @ViewBuilder
  private func block<Content: View>(
    title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Label(title, systemImage: systemImage)
        .font(captionSemibold)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .accessibilityAddTraits(.isHeader)
      content()
    }
    .padding(.top, HarnessMonitorTheme.spacingSM)
  }

  @ViewBuilder
  private func pillRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: HarnessMonitorTheme.spacingXS) { content() }
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) { content() }
    }
  }

  private func placeholder(_ text: String) -> some View {
    Text(text)
      .font(captionFont)
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
  }

  private func row(title: String, subtitle: String) -> some View {
    TaskBoardOperationsFormRow(title) {
      Text(subtitle)
        .font(captionFont)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(1)
    }
  }
}
