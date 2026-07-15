import HarnessMonitorIntents
import HarnessMonitorKit
import SwiftUI

/// Dispatch operations card. Owns its own filter/project-dir/actor @State
/// and hosts the dispatch confirmation dialog. Receives the unfiltered
/// `taskBoardItems` plus the parent's resolved `localHostProjectTypes`.
/// Board visibility, ordering, and host-aware filtering run in a presentation
/// worker so the operations card can update controls without scanning the
/// whole board on the main actor.
struct TaskBoardOperationsDispatchCard: View, TaskBoardOperationsHost {
  let store: HarnessMonitorStore
  let metrics: TaskBoardOverviewMetrics
  let dashboard: HarnessMonitorStore.ContentDashboardSlice
  let taskBoardItems: [TaskBoardItem]
  let localHostProjectTypes: [String]
  let isActive: Bool

  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.openWindow)
  private var openWindow

  @State private var statusChoice = TaskBoardStatusFilterChoice.all
  @State private var itemID: String?
  @State private var dryRun = true
  @State private var projectDir = ""
  @State private var actor = ""
  @State private var pendingConfirmation: TaskBoardDispatchConfirmationPresentation?
  @State private var presentationWorker = TaskBoardOperationsDispatchPresentationWorker()
  @State private var cachedPresentation = TaskBoardOperationsDispatchPresentation.empty
  @State private var presentedInput: TaskBoardOperationsDispatchPresentationInput?
  @State private var presentationGeneration: UInt64 = 0

  var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }
  var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  private var presentationInput: TaskBoardOperationsDispatchPresentationInput {
    TaskBoardOperationsDispatchPresentationInput(
      taskBoardItems: taskBoardItems,
      localHostProjectTypes: localHostProjectTypes
    )
  }

  private var activePresentationInput: TaskBoardOperationsDispatchPresentationInput? {
    isActive ? presentationInput : nil
  }

  private var isPresentationCurrent: Bool {
    guard isActive else { return false }
    return presentedInput == presentationInput
  }

  var body: some View {
    let validID = itemID.flatMap { id in
      cachedPresentation.item(id: id) == nil ? nil : id
    }
    let selectedItem = validID.flatMap { id in
      cachedPresentation.item(id: id)
    }

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
        itemID = cachedPresentation.item(id: newValue) == nil ? nil : newValue
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
          ForEach(cachedPresentation.dispatchableItems, id: \.id) { item in
            Text(item.title).tag(Optional(item.id))
          }
        }

        toggleField(
          "Dry run",
          isOn: $dryRun,
          accessibilityIdentifier: "harness.task-board.dispatch.dry-run"
        )
      }

      if cachedPresentation.didFilterOut {
        Text(
          "No items match this host's project types (\(formattedLocalHostProjectTypes)). "
            + "Set host project types in Settings or clear an item's Routes To list"
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
        Text("Live dispatch creates session work and requires confirmation")
          .font(captionFont)
          .foregroundStyle(HarnessMonitorTheme.caution)
          .padding(.top, HarnessMonitorTheme.spacingSM)
      }

      actionRow(
        showsSeparator: dashboard.taskBoardDispatchSummary != nil,
        accessory: { EmptyView() },
        content: {
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
            ),
            isDisabled: !isPresentationCurrent
          ) {
            if request.dryRun {
              enqueueDispatch(request)
            } else {
              pendingConfirmation = TaskBoardDispatchConfirmationPresentation(
                request: request,
                itemTitle: selectedItem?.title
              )
            }
          }
        }
      )

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
              appliedTaskRow(applied)
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
    .task(id: activePresentationInput) {
      guard let activePresentationInput else { return }
      await rebuildPresentation(input: activePresentationInput)
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
        let donatedItem = confirmation.request.itemId.flatMap(cachedPresentation.item(id:))
        if let donatedItem {
          HarnessMonitorIntentDonations.donateDispatch(items: [donatedItem])
        }
        enqueueDispatch(confirmation.request)
      }
      .disabled(
        store.isDaemonActionInFlight
          || store.contentUI.dashboard.connectionState != .online
          || !isPresentationCurrent
      )
      Button("Cancel", role: .cancel) {}
    } message: { confirmation in
      Text(confirmation.message)
    }
  }

  @MainActor
  private func rebuildPresentation(
    input: TaskBoardOperationsDispatchPresentationInput
  ) async {
    presentationGeneration &+= 1
    let generation = presentationGeneration
    let presentation = await presentationWorker.compute(input: input)
    guard !Task.isCancelled, presentationGeneration == generation else {
      return
    }
    if cachedPresentation != presentation {
      cachedPresentation = presentation
    }
    presentedInput = input
  }

  private func enqueueDispatch(_ request: TaskBoardDispatchRequest) {
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: request.dryRun ? "Previewing task board dispatch" : "Dispatching task board") {
        await store.dispatchTaskBoard(request: request)
      }
    )
  }

  /// Actionable variant of the shared applied-summary row: the spawned
  /// session/work-item ids gain an Open Session control that jumps into the
  /// live session window instead of leaving the ids as inert text.
  private func appliedTaskRow(_ applied: TaskBoardDispatchAppliedTask) -> some View {
    TaskBoardOperationsFormRow(applied.item.title) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        Text("\(applied.sessionId) · \(applied.workItemId)")
          .font(captionFont)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(1)
          .truncationMode(.middle)
        Button {
          TaskBoardSpawnedSessionNavigator.open(
            store: store,
            openWindow: openWindow,
            sessionID: applied.sessionId,
            workItemID: applied.workItemId
          )
        } label: {
          Label("Open Session", systemImage: "arrow.up.forward.app")
            .font(captionFont)
        }
        .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
        .controlSize(HarnessMonitorControlMetrics.compactControlSize)
        .help("Open the spawned session and focus its work item")
        .accessibilityIdentifier(
          "harness.task-board.dispatch.applied.open-session.\(applied.boardItemId)"
        )
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .accessibilityElement(children: .contain)
  }

  private var formattedLocalHostProjectTypes: String {
    let trimmed =
      localHostProjectTypes
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return trimmed.isEmpty ? "none declared" : trimmed.joined(separator: ", ")
  }
}
