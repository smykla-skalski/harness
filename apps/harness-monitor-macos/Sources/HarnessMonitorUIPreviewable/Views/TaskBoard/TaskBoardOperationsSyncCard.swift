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
  @Environment(\.openTaskBoardSettings)
  private var openTaskBoardSettings

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
  private var syncAvailability: TaskBoardGitHubSyncAvailability {
    TaskBoardGitHubSyncAvailability(
      settings: dashboard.taskBoardOrchestratorStatus?.settings
    )
  }

  var body: some View {
    let availability = syncAvailability
    TaskBoardOperationsCard(
      title: "Sync",
      metrics: metrics,
      footer: dashboard.taskBoardSyncSummary == nil
        ? "Run sync to preview or apply external pull and push operations"
        : nil,
      background: availability.warning == nil ? .standard : .warning
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

      if let warning = availability.warning {
        TaskBoardOperationsSyncWarning(message: warning) {
          openTaskBoardSettings(.githubProject)
        }
      }

      actionRow(
        showsSeparator: dashboard.taskBoardSyncSummary != nil,
        accessory: { EmptyView() },
        content: {
          actionButton(
            TaskBoardActionButtonDescriptor(
              title: dryRun ? "Preview Sync" : "Run Sync",
              systemImage: dryRun ? "eye" : "arrow.triangle.2.circlepath",
              tint: dryRun ? .secondary : nil,
              prominent: !dryRun,
              accessibilityIdentifier: "harness.task-board.sync.run",
              help: availability.warning ?? "Preview or apply external task-board sync operations"
            ),
            isDisabled: !availability.canRun
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
      )

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
      }
    }
  }
}

struct TaskBoardGitHubSyncAvailability: Equatable {
  let warning: String?

  init(settings: TaskBoardOrchestratorSettings?) {
    guard let settings, !settings.hasConfiguredGitHubSyncRepository else {
      warning = nil
      return
    }
    warning = "Configure a GitHub repository or inbox repository before running sync"
  }

  var canRun: Bool {
    warning == nil
  }
}

private struct TaskBoardOperationsSyncWarning: View {
  let message: String
  let openSettings: @MainActor () -> Void
  @Environment(\.fontScale)
  private var fontScale

  private var warningFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(message)
        .foregroundStyle(HarnessMonitorTheme.caution)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)

      Button {
        openSettings()
      } label: {
        Label("Task Board Settings", systemImage: "gearshape")
          .labelStyle(.titleAndIcon)
          .lineLimit(1)
      }
      .harnessActionButtonStyle(variant: .prominent, tint: HarnessMonitorTheme.accent)
      .harnessNativeFormControl()
      .fixedSize(horizontal: true, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityLabel("Open Task Board Settings")
      .accessibilityIdentifier("harness.task-board.sync.open-settings")
    }
    .font(warningFont)
    .padding(.vertical, TaskBoardOperationsFormMetrics.rowVerticalPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color(nsColor: .separatorColor))
        .frame(height: 0.5)
    }
    .accessibilityIdentifier("harness.task-board.sync.configuration-warning")
  }
}

extension TaskBoardOrchestratorSettings {
  fileprivate var hasConfiguredGitHubSyncRepository: Bool {
    hasConfiguredGitHubProjectRepository || hasConfiguredGitHubInboxRepository
  }

  fileprivate var hasConfiguredGitHubProjectRepository: Bool {
    !githubProject.owner.trimmedForTaskBoardSync.isEmpty
      && !githubProject.repo.trimmedForTaskBoardSync.isEmpty
  }

  fileprivate var hasConfiguredGitHubInboxRepository: Bool {
    githubInbox.repositories.contains { !$0.trimmedForTaskBoardSync.isEmpty }
  }
}

extension String {
  fileprivate var trimmedForTaskBoardSync: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
