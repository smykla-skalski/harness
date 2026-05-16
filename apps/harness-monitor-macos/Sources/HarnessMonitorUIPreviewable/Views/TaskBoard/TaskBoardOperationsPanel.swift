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
  @State private var localHostProjectTypes: [String] = []

  var metrics: TaskBoardOverviewMetrics {
    TaskBoardOverviewMetrics(fontScale: fontScale)
  }

  private var dashboard: HarnessMonitorStore.ContentDashboardSlice {
    store.contentUI.dashboard
  }

  /// Items the local host's `project_types` accept. Empty `targetProjectTypes`
  /// on an item routes to every host (mirrors Rust `Machine::accepts_any`).
  /// An empty result with non-zero source items means the host filtered them
  /// all out; we surface that to the user via an empty-state hint.
  fileprivate var dispatchableTaskBoardItems: [TaskBoardItem] {
    TaskBoardHostMachine.dispatchableItems(
      taskBoardItems,
      machineProjectTypes: localHostProjectTypes
    )
  }

  fileprivate var didFilterOutItems: Bool {
    !taskBoardItems.isEmpty && dispatchableTaskBoardItems.isEmpty
  }

  private var formattedLocalHostProjectTypes: String {
    let trimmed =
      localHostProjectTypes
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return trimmed.isEmpty ? "none declared" : trimmed.joined(separator: ", ")
  }

  private var validDispatchItemID: String? {
    guard let dispatchItemID else {
      return nil
    }
    return dispatchableTaskBoardItems.contains(where: { $0.id == dispatchItemID })
      ? dispatchItemID
      : nil
  }

  private var selectedDispatchItem: TaskBoardItem? {
    guard let validDispatchItemID else {
      return nil
    }
    return dispatchableTaskBoardItems.first(where: { $0.id == validDispatchItemID })
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
      set: { newValue in
        guard let newValue else {
          dispatchItemID = nil
          return
        }
        dispatchItemID = taskBoardItems.contains(where: { $0.id == newValue }) ? newValue : nil
      }
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
    .task { await loadLocalHostProjectTypes() }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.operations")
  }

  @MainActor
  private func loadLocalHostProjectTypes() async {
    do {
      let snapshot = try await store.taskBoardHostSnapshot()
      localHostProjectTypes = snapshot.local.projectTypes
    } catch {
      // Fail open: leave project types empty so dispatch shows every item.
      localHostProjectTypes = []
    }
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
          TaskBoardActionButtonDescriptor(
            title: syncDryRun ? "Preview Sync" : "Run Sync",
            systemImage: syncDryRun ? "eye" : "arrow.triangle.2.circlepath",
            tint: syncDryRun ? .secondary : nil,
            prominent: !syncDryRun,
            accessibilityIdentifier: "harness.task-board.sync.run",
            help: "Preview or apply external task-board sync operations"
          )
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
            ForEach(
              Array(summary.operations.prefix(4).enumerated()),
              id: \.offset
            ) { _, operation in
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
          ForEach(dispatchableTaskBoardItems, id: \.id) { item in
            Text(item.title).tag(Optional(item.id))
          }
        }

        toggleField(
          "Dry run",
          isOn: $dispatchDryRun,
          accessibilityIdentifier: "harness.task-board.dispatch.dry-run"
        )
      }

      if didFilterOutItems {
        Text(
          "No items match this host's project types (\(formattedLocalHostProjectTypes)). "
            + "Set host project types in Settings or clear an item's Routes To list."
        )
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.caution)
        .accessibilityIdentifier("harness.task-board.dispatch.host-mismatch")
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
          TaskBoardActionButtonDescriptor(
            title: dispatchDryRun ? "Preview Dispatch" : "Dispatch Live",
            systemImage: dispatchDryRun ? "eye" : "paperplane.fill",
            tint: dispatchDryRun ? .secondary : .orange,
            prominent: !dispatchDryRun,
            accessibilityIdentifier: "harness.task-board.dispatch.run",
            help: dispatchDryRun
              ? "Preview how task-board items will dispatch"
              : "Dispatch the selected board scope into live session work"
          )
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
    TaskBoardOperationsPanelInventoryCard(
      store: store,
      dashboard: dashboard,
      metrics: metrics,
      inventoryStatusChoice: $inventoryStatusChoice
    )
  }
}
