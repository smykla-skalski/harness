import HarnessMonitorKit
import SwiftUI

/// Dispatch operations card. Owns its own filter/project-dir/actor @State
/// and hosts the dispatch confirmation dialog. Receives the unfiltered
/// `taskBoardItems` plus the parent's resolved `localHostProjectTypes` -
/// the host-aware dispatchable subset is computed once at the top of
/// `body` and reused by every reader to avoid the 3-4 redundant filter
/// passes the inline-computed-property version did.
struct TaskBoardOperationsDispatchCard: View, TaskBoardOperationsHost {
  let store: HarnessMonitorStore
  let metrics: TaskBoardOverviewMetrics
  let dashboard: HarnessMonitorStore.ContentDashboardSlice
  let taskBoardItems: [TaskBoardItem]
  let localHostProjectTypes: [String]

  @Environment(\.fontScale)
  private var fontScale

  @State private var statusChoice = TaskBoardStatusFilterChoice.all
  @State private var itemID: String?
  @State private var dryRun = true
  @State private var projectDir = ""
  @State private var actor = ""
  @State private var pendingConfirmation: TaskBoardDispatchConfirmationPresentation?

  var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }
  var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    let dispatchableItems = TaskBoardHostMachine.dispatchableItems(
      taskBoardItems,
      machineProjectTypes: localHostProjectTypes
    )
    let validID = itemID.flatMap { id in
      dispatchableItems.contains(where: { $0.id == id }) ? id : nil
    }
    let selectedItem = validID.flatMap { id in
      dispatchableItems.first(where: { $0.id == id })
    }
    let didFilterOut = !taskBoardItems.isEmpty && dispatchableItems.isEmpty

    let request = TaskBoardDispatchRequest(
      status: validID == nil ? statusChoice.status : nil,
      itemId: validID,
      dryRun: dryRun,
      projectDir: projectDir.taskBoardNilIfEmpty,
      actor: actor.taskBoardNilIfEmpty
    )

    let selectionBinding = Binding<String?>(
      get: { validID },
      set: { newValue in
        guard let newValue else {
          itemID = nil
          return
        }
        itemID = taskBoardItems.contains(where: { $0.id == newValue }) ? newValue : nil
      }
    )

    return TaskBoardOperationsCard(
      title: "Dispatch",
      metrics: metrics,
      footer: dashboard.taskBoardDispatchSummary == nil
        ? "Preview dispatch to inspect readiness and resulting session work"
        : nil
    ) {
      controlRows {
        pickerField(
          "Status filter",
          selection: $statusChoice,
          accessibilityIdentifier: "harness.task-board.dispatch.status"
        ) {
          ForEach(TaskBoardStatusFilterChoice.stableAllCases) { choice in
            Text(choice.title).tag(choice)
          }
        }

        pickerField(
          "Board item",
          selection: selectionBinding,
          accessibilityIdentifier: "harness.task-board.dispatch.item"
        ) {
          Text("All matching items").tag(Optional<String>.none)
          ForEach(dispatchableItems, id: \.id) { item in
            Text(item.title).tag(Optional(item.id))
          }
        }

        toggleField(
          "Dry run",
          isOn: $dryRun,
          accessibilityIdentifier: "harness.task-board.dispatch.dry-run"
        )
      }

      if didFilterOut {
        Text(
          "No items match this host's project types (\(formattedLocalHostProjectTypes)). "
            + "Set host project types in Settings or clear an item's Routes To list."
        )
        .font(captionFont)
        .foregroundStyle(HarnessMonitorTheme.caution)
        .padding(.top, HarnessMonitorTheme.spacingSM)
        .accessibilityIdentifier("harness.task-board.dispatch.host-mismatch")
      }

      controlRows {
        textField(
          "Project directory",
          text: $projectDir,
          prompt: "/path/to/project",
          accessibilityIdentifier: "harness.task-board.dispatch.project-dir"
        )

        textField(
          "Actor",
          text: $actor,
          prompt: "Optional actor",
          accessibilityIdentifier: "harness.task-board.dispatch.actor"
        )
      }

      if !dryRun {
        Text("Live dispatch creates session work and requires confirmation.")
          .font(captionFont)
          .foregroundStyle(HarnessMonitorTheme.caution)
          .padding(.top, HarnessMonitorTheme.spacingSM)
      }

      actionRow(showsSeparator: dashboard.taskBoardDispatchSummary != nil) {
        actionButton(
          TaskBoardActionButtonDescriptor(
            title: dryRun ? "Preview Dispatch" : "Dispatch Live",
            systemImage: dryRun ? "eye" : "paperplane.fill",
            tint: dryRun ? .secondary : .orange,
            prominent: !dryRun,
            accessibilityIdentifier: "harness.task-board.dispatch.run",
            help: dryRun
              ? "Preview how task-board items will dispatch"
              : "Dispatch the selected board scope into live session work"
          )
        ) {
          if request.dryRun {
            Task { @MainActor in
              await store.dispatchTaskBoard(request: request)
            }
          } else {
            pendingConfirmation = TaskBoardDispatchConfirmationPresentation(
              request: request,
              itemTitle: selectedItem?.title
            )
          }
        }
      }

      if let summary = dashboard.taskBoardDispatchSummary {
        summaryPillRow {
          TaskBoardSummaryPill(value: "\(summary.plans.count)", label: "Plans")
          let readyCount = summary.plans.count { $0.readiness.isReady }
          TaskBoardSummaryPill(
            value: "\(readyCount)", label: "Ready", tint: HarnessMonitorTheme.accent)
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
              .font(captionSemibold)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .accessibilityAddTraits(.isHeader)
            ForEach(summary.applied.prefix(4)) { applied in
              appliedSummaryRow(applied)
            }
          }
          .padding(.top, HarnessMonitorTheme.spacingSM)
        } else if !summary.plans.isEmpty {
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
            Text("Plans")
              .font(captionSemibold)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .accessibilityAddTraits(.isHeader)
            ForEach(summary.plans.prefix(4)) { plan in
              planSummaryRow(plan)
            }
          }
          .padding(.top, HarnessMonitorTheme.spacingSM)
        } else {
          placeholderText("No board items matched the current dispatch filter")
        }
      }
    }
    .confirmationDialog(
      pendingConfirmation?.title ?? "Dispatch items?",
      isPresented: Binding(
        get: { pendingConfirmation != nil },
        set: { if !$0 { pendingConfirmation = nil } }
      ),
      presenting: pendingConfirmation
    ) { confirmation in
      Button("Dispatch", role: .destructive) {
        pendingConfirmation = nil
        Task { @MainActor in
          await store.dispatchTaskBoard(request: confirmation.request)
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: { confirmation in
      Text(confirmation.message)
    }
  }

  private var formattedLocalHostProjectTypes: String {
    let trimmed =
      localHostProjectTypes
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return trimmed.isEmpty ? "none declared" : trimmed.joined(separator: ", ")
  }
}
