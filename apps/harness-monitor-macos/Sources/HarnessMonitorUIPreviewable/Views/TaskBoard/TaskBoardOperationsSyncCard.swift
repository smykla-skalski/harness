import HarnessMonitorKit
import SwiftUI

/// Sync operations card. Owns its own filter/direction/dry-run @State so a
/// change here does not invalidate the Dispatch or Inventory cards (each
/// is its own View struct with isolated state).
struct TaskBoardOperationsSyncCard: View, TaskBoardOperationsHost {
  let store: HarnessMonitorStore
  let metrics: TaskBoardOverviewMetrics
  let dashboard: HarnessMonitorStore.ContentDashboardSlice

  @Environment(\.fontScale)
  private var fontScale

  @State private var statusChoice = TaskBoardStatusFilterChoice.all
  @State private var direction = TaskBoardExternalSyncDirection.both
  @State private var dryRun = true

  var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }
  var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  private var providerChoice: TaskBoardExternalProviderChoice { .monitorVisibleChoice }

  var body: some View {
    TaskBoardOperationsCard(
      title: "Sync",
      metrics: metrics
    ) {
      controlRows {
        pickerField(
          "Status filter",
          selection: $statusChoice,
          accessibilityIdentifier: "harness.task-board.sync.status"
        ) {
          ForEach(TaskBoardStatusFilterChoice.stableAllCases) { choice in
            Text(choice.title).tag(choice)
          }
        }

        staticField(
          "Provider",
          value: providerChoice.title,
          accessibilityIdentifier: "harness.task-board.sync.provider"
        )

        pickerField(
          "Direction",
          selection: $direction,
          accessibilityIdentifier: "harness.task-board.sync.direction"
        ) {
          ForEach(TaskBoardExternalSyncDirection.allCases, id: \.rawValue) { direction in
            Text(direction.title).tag(direction)
          }
        }

        toggleField(
          "Dry run",
          isOn: $dryRun,
          accessibilityIdentifier: "harness.task-board.sync.dry-run"
        )
      }

      actionRow {
        actionButton(
          TaskBoardActionButtonDescriptor(
            title: dryRun ? "Preview Sync" : "Run Sync",
            systemImage: dryRun ? "eye" : "arrow.triangle.2.circlepath",
            tint: dryRun ? .secondary : nil,
            prominent: !dryRun,
            accessibilityIdentifier: "harness.task-board.sync.run",
            help: "Preview or apply external task-board sync operations"
          )
        ) {
          Task { @MainActor in
            await store.syncTaskBoard(
              request: TaskBoardSyncRequest(
                status: statusChoice.status,
                provider: providerChoice.provider,
                direction: direction,
                dryRun: dryRun
              )
            )
          }
        }
      }

      if let summary = dashboard.taskBoardSyncSummary {
        let visibleProviders = summary.monitorVisibleProviders
        let visibleOperations = summary.monitorVisibleOperations
        summaryPillRow {
          TaskBoardSummaryPill(value: "\(summary.total)", label: "Items")
          TaskBoardSummaryPill(value: "\(visibleProviders.count)", label: "Providers")
          TaskBoardSummaryPill(value: "\(visibleOperations.count)", label: "Ops")
          let appliedCount = visibleOperations.count { $0.applied }
          if appliedCount != 0 {
            TaskBoardSummaryPill(
              value: "\(appliedCount)",
              label: "Applied",
              tint: HarnessMonitorTheme.accent
            )
          }
        }

        if !visibleProviders.isEmpty {
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
            Text("Providers")
              .font(captionSemibold)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .accessibilityAddTraits(.isHeader)
            ForEach(visibleProviders, id: \.provider.rawValue) { provider in
              providerSummaryRow(provider)
            }
          }
          .padding(.top, HarnessMonitorTheme.spacingSM)
        }

        if !visibleOperations.isEmpty {
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
            Text("Recent operations")
              .font(captionSemibold)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .accessibilityAddTraits(.isHeader)
            ForEach(
              Array(visibleOperations.prefix(4).enumerated()),
              id: \.offset
            ) { _, operation in
              operationSummaryRow(operation)
            }
          }
          .padding(.top, HarnessMonitorTheme.spacingSM)
        }
      } else {
        placeholderText("Run sync to preview or apply external pull and push operations.")
      }
    }
  }
}
