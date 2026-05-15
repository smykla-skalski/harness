import HarnessMonitorKit
import SwiftUI

struct TaskBoardOperationsPanel: View {
  let store: HarnessMonitorStore
  let taskBoardItems: [TaskBoardItem]

  @Environment(\.fontScale)
  private var fontScale

  @State private var syncStatusChoice = TaskBoardStatusFilterChoice.all
  @State private var syncProviderChoice = TaskBoardExternalProviderChoice.all
  @State private var syncDirection = TaskBoardExternalSyncDirection.both
  @State private var syncDryRun = true

  @State private var dispatchStatusChoice = TaskBoardStatusFilterChoice.all
  @State private var dispatchItemID: String?
  @State private var dispatchDryRun = true
  @State private var dispatchProjectDir = ""
  @State private var dispatchActor = ""

  @State private var inventoryStatusChoice = TaskBoardStatusFilterChoice.all
  @State private var pendingDispatchConfirmation: TaskBoardDispatchConfirmationPresentation?

  var metrics: TaskBoardOverviewMetrics {
    TaskBoardOverviewMetrics(fontScale: fontScale)
  }

  private var dashboard: HarnessMonitorStore.ContentDashboardSlice {
    store.contentUI.dashboard
  }

  private var validDispatchItemID: String? {
    guard let dispatchItemID else {
      return nil
    }
    return taskBoardItems.contains(where: { $0.id == dispatchItemID }) ? dispatchItemID : nil
  }

  private var selectedDispatchItem: TaskBoardItem? {
    guard let validDispatchItemID else {
      return nil
    }
    return taskBoardItems.first(where: { $0.id == validDispatchItemID })
  }

  private var dispatchRequest: TaskBoardDispatchRequest {
    TaskBoardDispatchRequest(
      status: validDispatchItemID == nil ? dispatchStatusChoice.status : nil,
      itemId: validDispatchItemID,
      dryRun: dispatchDryRun,
      projectDir: dispatchProjectDir.taskBoardNilIfEmpty,
      actor: dispatchActor.taskBoardNilIfEmpty
    )
  }

  private var dispatchSelectionBinding: Binding<String?> {
    Binding(
      get: { validDispatchItemID },
      set: { dispatchItemID = $0 }
    )
  }

  var body: some View {
    TaskBoardSection(title: "Operations") {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        syncCard
        dispatchCard
        inventoryCard
      }
    }
    .confirmationDialog(
      pendingDispatchConfirmation?.title ?? "Dispatch items?",
      isPresented: Binding(
        get: { pendingDispatchConfirmation != nil },
        set: { if !$0 { pendingDispatchConfirmation = nil } }
      ),
      presenting: pendingDispatchConfirmation
    ) { confirmation in
      Button("Dispatch", role: .destructive) {
        pendingDispatchConfirmation = nil
        Task { @MainActor in
          await store.dispatchTaskBoard(request: confirmation.request)
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: { confirmation in
      Text(confirmation.message)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.operations")
  }
}

extension TaskBoardOperationsPanel {
  private var syncCard: some View {
    TaskBoardOperationsCard(
      title: "Sync",
      systemImage: "arrow.triangle.2.circlepath",
      metrics: metrics
    ) {
      controlRows {
        pickerField(
          "Status filter",
          selection: $syncStatusChoice,
          accessibilityIdentifier: "harness.task-board.sync.status"
        ) {
          ForEach(TaskBoardStatusFilterChoice.allCases) { choice in
            Text(choice.title).tag(choice)
          }
        }

        pickerField(
          "Provider",
          selection: $syncProviderChoice,
          accessibilityIdentifier: "harness.task-board.sync.provider"
        ) {
          ForEach(TaskBoardExternalProviderChoice.allCases) { choice in
            Text(choice.title).tag(choice)
          }
        }

        pickerField(
          "Direction",
          selection: $syncDirection,
          accessibilityIdentifier: "harness.task-board.sync.direction"
        ) {
          ForEach(TaskBoardExternalSyncDirection.allCases, id: \.rawValue) { direction in
            Text(direction.title).tag(direction)
          }
        }

        toggleField(
          "Dry run",
          isOn: $syncDryRun,
          accessibilityIdentifier: "harness.task-board.sync.dry-run"
        )
      }

      actionRow {
        actionButton(
          title: syncDryRun ? "Preview Sync" : "Run Sync",
          systemImage: syncDryRun ? "eye" : "arrow.triangle.2.circlepath",
          tint: syncDryRun ? .secondary : nil,
          prominent: !syncDryRun,
          accessibilityIdentifier: "harness.task-board.sync.run",
          help: "Preview or apply external task-board sync operations"
        ) {
          Task { @MainActor in
            await store.syncTaskBoard(
              request: TaskBoardSyncRequest(
                status: syncStatusChoice.status,
                provider: syncProviderChoice.provider,
                direction: syncDirection,
                dryRun: syncDryRun
              )
            )
          }
        }
      }

      if let summary = dashboard.taskBoardSyncSummary {
        summaryPillRow {
          TaskBoardSummaryPill(value: "\(summary.total)", label: "Items")
          TaskBoardSummaryPill(value: "\(summary.providers.count)", label: "Providers")
          TaskBoardSummaryPill(value: "\(summary.operations.count)", label: "Ops")
          let appliedCount = summary.operations.count { $0.applied }
          if appliedCount != 0 {
            TaskBoardSummaryPill(
              value: "\(appliedCount)",
              label: "Applied",
              tint: HarnessMonitorTheme.accent
            )
          }
        }

        if !summary.providers.isEmpty {
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
            Text("Providers")
              .scaledFont(.caption.weight(.semibold))
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .accessibilityAddTraits(.isHeader)
            ForEach(summary.providers, id: \.provider.rawValue) { provider in
              providerSummaryRow(provider)
            }
          }
        }

        if !summary.operations.isEmpty {
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
            Text("Recent operations")
              .scaledFont(.caption.weight(.semibold))
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .accessibilityAddTraits(.isHeader)
            ForEach(Array(summary.operations.prefix(4).enumerated()), id: \.offset) { _, operation in
              operationSummaryRow(operation)
            }
          }
        }
      } else {
        placeholderText("Run sync to preview or apply external pull and push operations.")
      }
    }
  }

  private var dispatchCard: some View {
    TaskBoardOperationsCard(
      title: "Dispatch",
      systemImage: "paperplane",
      metrics: metrics
    ) {
      controlRows {
        pickerField(
          "Status filter",
          selection: $dispatchStatusChoice,
          accessibilityIdentifier: "harness.task-board.dispatch.status"
        ) {
          ForEach(TaskBoardStatusFilterChoice.allCases) { choice in
            Text(choice.title).tag(choice)
          }
        }

        pickerField(
          "Board item",
          selection: dispatchSelectionBinding,
          accessibilityIdentifier: "harness.task-board.dispatch.item"
        ) {
          Text("All matching items").tag(Optional<String>.none)
          ForEach(taskBoardItems, id: \.id) { item in
            Text(item.title).tag(Optional(item.id))
          }
        }

        toggleField(
          "Dry run",
          isOn: $dispatchDryRun,
          accessibilityIdentifier: "harness.task-board.dispatch.dry-run"
        )
      }

      controlRows {
        textField(
          "Project directory",
          text: $dispatchProjectDir,
          prompt: "/path/to/project",
          accessibilityIdentifier: "harness.task-board.dispatch.project-dir"
        )

        textField(
          "Actor",
          text: $dispatchActor,
          prompt: "Optional actor",
          accessibilityIdentifier: "harness.task-board.dispatch.actor"
        )
      }

      if !dispatchDryRun {
        Text("Live dispatch creates session work and requires confirmation.")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.caution)
      }

      actionRow {
        actionButton(
          title: dispatchDryRun ? "Preview Dispatch" : "Dispatch Live",
          systemImage: dispatchDryRun ? "eye" : "paperplane.fill",
          tint: dispatchDryRun ? .secondary : .orange,
          prominent: !dispatchDryRun,
          accessibilityIdentifier: "harness.task-board.dispatch.run",
          help: dispatchDryRun
            ? "Preview how task-board items will dispatch"
            : "Dispatch the selected board scope into live session work"
        ) {
          if dispatchRequest.dryRun {
            Task { @MainActor in
              await store.dispatchTaskBoard(request: dispatchRequest)
            }
          } else {
            pendingDispatchConfirmation = TaskBoardDispatchConfirmationPresentation(
              request: dispatchRequest,
              itemTitle: selectedDispatchItem?.title
            )
          }
        }
      }

      if let summary = dashboard.taskBoardDispatchSummary {
        summaryPillRow {
          TaskBoardSummaryPill(value: "\(summary.plans.count)", label: "Plans")
          let readyCount = summary.plans.count { $0.readiness.isReady }
          TaskBoardSummaryPill(value: "\(readyCount)", label: "Ready", tint: HarnessMonitorTheme.accent)
          let blockedCount = summary.plans.count { !$0.readiness.isReady }
          if blockedCount != 0 {
            TaskBoardSummaryPill(
              value: "\(blockedCount)",
              label: "Blocked",
              tint: HarnessMonitorTheme.danger
            )
          }
          if !summary.applied.isEmpty {
            TaskBoardSummaryPill(
              value: "\(summary.applied.count)",
              label: "Applied",
              tint: HarnessMonitorTheme.accent
            )
          }
        }

        if !summary.applied.isEmpty {
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
            Text("Applied")
              .scaledFont(.caption.weight(.semibold))
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .accessibilityAddTraits(.isHeader)
            ForEach(summary.applied.prefix(4)) { applied in
              appliedSummaryRow(applied)
            }
          }
        } else if !summary.plans.isEmpty {
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
            Text("Plans")
              .scaledFont(.caption.weight(.semibold))
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .accessibilityAddTraits(.isHeader)
            ForEach(summary.plans.prefix(4)) { plan in
              planSummaryRow(plan)
            }
          }
        } else {
          placeholderText("No board items matched the current dispatch filter.")
        }
      } else {
        placeholderText("Preview dispatch to inspect readiness and resulting session work.")
      }
    }
  }

  private var inventoryCard: some View {
    TaskBoardOperationsCard(
      title: "Audit & Inventory",
      systemImage: "list.bullet.rectangle.portrait",
      metrics: metrics
    ) {
      controlRows {
        pickerField(
          "Status filter",
          selection: $inventoryStatusChoice,
          accessibilityIdentifier: "harness.task-board.inventory.status"
        ) {
          ForEach(TaskBoardStatusFilterChoice.allCases) { choice in
            Text(choice.title).tag(choice)
          }
        }
      }

      actionRow {
        actionButton(
          title: "Audit",
          systemImage: "checkmark.shield",
          tint: .secondary,
          accessibilityIdentifier: "harness.task-board.audit.run",
          help: "Load board status audit counts"
        ) {
          Task { @MainActor in
            await store.auditTaskBoard(status: inventoryStatusChoice.status)
          }
        }

        actionButton(
          title: "Projects",
          systemImage: "folder",
          tint: .secondary,
          accessibilityIdentifier: "harness.task-board.projects.run",
          help: "Load task-board project summary counts"
        ) {
          Task { @MainActor in
            await store.refreshTaskBoardProjects(status: inventoryStatusChoice.status)
          }
        }

        actionButton(
          title: "Machines",
          systemImage: "desktopcomputer",
          tint: .secondary,
          accessibilityIdentifier: "harness.task-board.machines.run",
          help: "Load task-board machine summary counts"
        ) {
          Task { @MainActor in
            await store.refreshTaskBoardMachines(status: inventoryStatusChoice.status)
          }
        }
      }

      inventorySummaryContent
    }
  }

  @ViewBuilder private var inventorySummaryContent: some View {
    inventoryBlock(title: "Audit", systemImage: "checkmark.shield") {
      if let audit = dashboard.taskBoardItemAuditSummary {
        summaryPillRow {
          TaskBoardSummaryPill(value: "\(audit.total)", label: "Total")
          TaskBoardSummaryPill(value: "\(audit.ready)", label: "Ready", tint: HarnessMonitorTheme.accent)
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
          summaryPillRow {
            ForEach(audit.byStatus, id: \.status.id) { count in
              TaskBoardSummaryPill(
                value: "\(count.count)",
                label: count.status.title,
                tint: taskBoardStatusColor(for: count.status)
              )
            }
          }
        }
      } else {
        placeholderText("Load a task-board audit to inspect readiness and status totals.")
      }
    }

    inventoryBlock(title: "Projects", systemImage: "folder") {
      if let projects = dashboard.taskBoardProjects {
        if projects.isEmpty {
          placeholderText("No matching projects.")
        } else {
          ForEach(projects.prefix(5)) { project in
            keyedSummaryRow(
              title: project.projectId,
              subtitle: "\(project.readyCount) ready of \(project.itemCount) items"
            )
          }
        }
      } else {
        placeholderText("Load project summaries for the current board filter.")
      }
    }

    inventoryBlock(title: "Machines", systemImage: "desktopcomputer") {
      if let machines = dashboard.taskBoardMachines {
        if machines.isEmpty {
          placeholderText("No matching machine modes.")
        } else {
          ForEach(machines.prefix(5)) { machine in
            keyedSummaryRow(
              title: machine.mode.title,
              subtitle: "\(machine.readyCount) ready of \(machine.itemCount) items"
            )
          }
        }
      } else {
        placeholderText("Load machine summaries for the current board filter.")
      }
    }
  }
}
