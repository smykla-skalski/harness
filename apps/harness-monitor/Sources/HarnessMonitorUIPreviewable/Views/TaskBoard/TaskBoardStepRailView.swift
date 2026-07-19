import HarnessMonitorKit
import SwiftUI

struct TaskBoardStepRailView: View {
  let store: HarnessMonitorStore
  let status: TaskBoardOrchestratorStatus
  let latestEvaluation: TaskBoardEvaluationSummary?
  let workspace: PolicyCanvasWorkspace?
  let targetItem: TaskBoardItem?
  let taskBoardItems: [TaskBoardItem]
  let isActionInFlight: Bool
  let actions: TaskBoardOverviewActions

  @Environment(\.openWindow)
  var openWindow
  @Environment(\.openURL)
  var openURL
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @State private var state = TaskBoardStepRailState()

  var stepRailState: TaskBoardStepRailState { state }

  /// The item the flow follows: the locked item resolved to its live board copy,
  /// falling back to the current target (top Todo) when nothing is locked.
  var lockedItem: TaskBoardItem? {
    if let id = state.lockedItemID, let live = taskBoardItems.first(where: { $0.id == id }) {
      return live
    }
    return targetItem
  }

  var activeItem: TaskBoardItem? { lockedItem }

  private var latestRecord: TaskBoardEvaluationRecord? {
    guard let id = lockedItem?.id else { return nil }
    return latestEvaluation?.records.first { $0.boardItemId == id }
  }

  private var stagePlan: TaskBoardStepStagePlan {
    TaskBoardStepStageResolver.plan(
      for: TaskBoardStepStageInputs(
        item: lockedItem,
        latestRecord: latestRecord,
        hasPicked: state.pickedSelection != nil,
        hasDelivered: state.delivery != nil
      )
    )
  }

  private var controlsDisabled: Bool {
    isActionInFlight || state.isBusy || store.contentUI.dashboard.connectionState != .online
  }

  private var cardIdentity: String {
    if let viewing = state.viewingColumn, viewing != stagePlan.column {
      return "preview-\(viewing.rawValue)"
    }
    return "live-\(stagePlan.stage.rawValue)"
  }

  private var cautionFont: Font {
    HarnessMonitorTextSize.scaledFont(.callout.weight(.semibold), by: fontScale)
  }
  private var primaryButtonFont: Font {
    HarnessMonitorTextSize.scaledFont(.callout.weight(.semibold), by: fontScale)
  }
  private var linkFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  var body: some View {
    TaskBoardSection(title: "Manual Steps") {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        TaskBoardStepRailTargetView(item: activeItem, isPicked: state.pickedSelection != nil)
        Label("Live manual operations", systemImage: "bolt.shield.fill")
          .font(cautionFont)
          .foregroundStyle(HarnessMonitorTheme.caution)
          .accessibilityIdentifier("harness.task-board.step.live-mode")
        TaskBoardStepProgressRail(
          current: stagePlan.column,
          isBlocked: stagePlan.isBlockedColumn,
          viewing: state.viewingColumn,
          state: state
        )
        cardArea
        contextDisclosure
      }
      .padding(HarnessMonitorTheme.spacingMD)
      .background(HarnessMonitorTheme.ink.opacity(0.025), in: .rect(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(HarnessMonitorTheme.ink.opacity(0.12))
      }
    }
    .confirmationDialog(
      confirmationTitle,
      isPresented: confirmationPresented,
      presenting: state.confirmation
    ) { confirmation in
      confirmationActions(confirmation)
    } message: { confirmation in
      Text(confirmationMessage(confirmation))
    }
    .onChange(of: status.stepMode) {
      if !status.stepMode { state.reset() }
    }
    .onChange(of: stagePlan.stage) { _, newStage in
      AccessibilityNotification.Announcement("Step Mode stage: \(newStage.title)").post()
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.step-rail")
  }

  private var cardArea: some View {
    Group {
      if stagePlan.stage == .noTarget {
        emptyState
      } else if let viewing = state.viewingColumn, viewing != stagePlan.column {
        previewCard(for: viewing)
      } else {
        liveCard(stagePlan)
      }
    }
    .id(cardIdentity)
    .transition(.opacity)
    .animation(.easeInOut(duration: reduceMotion ? 0 : 0.2), value: cardIdentity)
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label("No ready item", systemImage: "tray")
    } description: {
      Text(stagePlan.whatNext)
    } actions: {
      Button {
        state.confirmation = .externalSync
      } label: {
        Label("Sync external sources", systemImage: "arrow.triangle.2.circlepath")
      }
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      .disabled(controlsDisabled)
    }
    .accessibilityIdentifier("harness.task-board.step.empty")
  }

  private func previewCard(for column: TaskBoardStepColumn) -> some View {
    TaskBoardStepStageCard(
      stageTitle: column.title,
      whatHappened: nil,
      whatNext: column.explanation
    ) {
      Button {
        state.viewingColumn = nil
      } label: {
        Label("Back to current step", systemImage: "arrow.uturn.backward").font(linkFont)
      }
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      .controlSize(.small)
      .accessibilityIdentifier("harness.task-board.step.back-to-current")
    }
  }

  private func liveCard(_ plan: TaskBoardStepStagePlan) -> some View {
    TaskBoardStepStageCard(
      stageTitle: plan.stage.title,
      whatHappened: plan.whatHappened,
      whatNext: plan.whatNext
    ) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        if plan.stage == .readyToDeliver, let selection = state.pickedSelection {
          TaskBoardStepPromptPreview(prompt: selection.plan.renderedPrompt)
        }
        if let action = plan.primaryAction {
          primaryButton(action)
        }
        if !plan.inlineLinks.isEmpty {
          inlineLinksRow(plan.inlineLinks)
        }
        secondaryRow(plan)
      }
    }
  }

  @ViewBuilder
  private func secondaryRow(_ plan: TaskBoardStepStagePlan) -> some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      if plan.primaryAction != .sync {
        syncButton
      }
      if plan.stage == .done, plan.primaryAction == nil {
        Button {
          state.resetFlow()
        } label: {
          Label("Start next item", systemImage: "forward.end").font(linkFont)
        }
        .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
        .controlSize(.small)
        .accessibilityIdentifier("harness.task-board.step.start-next")
      }
    }
  }

  private func primaryButton(_ action: TaskBoardStepPrimaryAction) -> some View {
    Button {
      runPrimary(action)
    } label: {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        if state.isBusy {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: primaryIcon(action))
        }
        Text("Next: \(action.buttonTitle)")
      }
      .font(primaryButtonFont)
      .frame(maxWidth: .infinity)
    }
    .harnessActionButtonStyle(variant: .prominent)
    .controlSize(.large)
    .disabled(controlsDisabled)
    .accessibilityLabel("Next, \(action.buttonTitle)")
    .accessibilityHint(stagePlan.whatNext)
    .accessibilityIdentifier("harness.task-board.step.next")
  }

  private func inlineLinksRow(_ links: [TaskBoardStepInlineLink]) -> some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      ForEach(links) { link in
        Button {
          runLink(link)
        } label: {
          Label(link.title, systemImage: linkIcon(link)).font(linkFont)
        }
        .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
        .controlSize(.small)
        .accessibilityIdentifier("harness.task-board.step.link.\(link.rawValue)")
      }
    }
  }

  private var syncButton: some View {
    Button {
      state.confirmation = .externalSync
    } label: {
      Label("Sync external sources", systemImage: "arrow.triangle.2.circlepath").font(linkFont)
    }
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .controlSize(.small)
    .disabled(controlsDisabled)
    .accessibilityIdentifier("harness.task-board.step.sync")
  }

  private func primaryIcon(_ action: TaskBoardStepPrimaryAction) -> String {
    switch action {
    case .sync: "arrow.triangle.2.circlepath"
    case .pick: "arrow.up.to.line"
    case .deliver: "paperplane.fill"
    case .evaluate: "checkmark.seal"
    case .complete: "checkmark.circle.fill"
    }
  }

  private func linkIcon(_ link: TaskBoardStepInlineLink) -> String {
    switch link {
    case .watch: "eye"
    case .openTask: "person.2.badge.gearshape"
    case .openPullRequest: "arrow.up.forward.square"
    }
  }

  func runPrimary(_ action: TaskBoardStepPrimaryAction) {
    switch action {
    case .sync: state.confirmation = .externalSync
    case .pick: enqueuePick()
    case .deliver: state.confirmation = .deliver
    case .evaluate: state.confirmation = .evaluate
    case .complete: state.confirmation = .complete
    }
  }

  func runLink(_ link: TaskBoardStepInlineLink) {
    switch link {
    case .watch:
      openSpawnedAgent()
    case .openTask:
      openReview()
    case .openPullRequest:
      if let raw = lockedItem?.workflow?.prUrl, let url = URL(string: raw) {
        openURL(url)
      }
    }
  }

  private var contextDisclosure: some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        TaskBoardApprovalGrantsView(
          store: store,
          workspace: workspace,
          refreshID: approvalGrantRefreshID,
          isDisabled: controlsDisabled
        )
        HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingXL) {
          TaskBoardHeldDispatchesView(summary: status.heldDispatches)
            .frame(maxWidth: .infinity, alignment: .topLeading)
          TaskBoardPolicyGuardsView(workspace: workspace)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
      }
      .padding(.top, HarnessMonitorTheme.spacingSM)
    } label: {
      Label("Automation context", systemImage: "gearshape.2").font(cautionFont)
    }
    .accessibilityIdentifier("harness.task-board.step.context")
  }

  private var confirmationPresented: Binding<Bool> {
    Binding(
      get: { state.confirmation != nil },
      set: { if !$0 { state.confirmation = nil } }
    )
  }

  private var confirmationTitle: String {
    switch state.confirmation {
    case .externalSync: "Run live external sync?"
    case .evaluate: "Run live task-board evaluation?"
    case .deliver: "Deliver and spawn this item?"
    case .complete: "Complete this board item?"
    case nil: "Confirm manual step"
    }
  }

  @ViewBuilder
  private func confirmationActions(
    _ confirmation: TaskBoardStepRailState.Confirmation
  ) -> some View {
    switch confirmation {
    case .externalSync:
      Button("Sync Live", role: .destructive) {
        state.confirmation = nil
        enqueueExternalSync()
      }
      .disabled(controlsDisabled)
    case .evaluate:
      Button("Evaluate Live", role: .destructive) {
        state.confirmation = nil
        enqueueEvaluation()
      }
      .disabled(controlsDisabled)
    case .deliver:
      Button("Deliver Live", role: .destructive) {
        state.confirmation = nil
        enqueueDelivery()
      }
      .disabled(controlsDisabled)
    case .complete:
      Button("Complete", role: .destructive) {
        state.confirmation = nil
        enqueueCompletion()
      }
      .disabled(controlsDisabled)
    }
    Button("Cancel", role: .cancel) {}
  }

  private func confirmationMessage(_ confirmation: TaskBoardStepRailState.Confirmation) -> String {
    let title = activeItem?.title ?? "the current item"
    return switch confirmation {
    case .externalSync:
      "This pulls external task sources and applies changes to the live board"
    case .evaluate:
      "This evaluates \(title) and applies any resulting board transition"
    case .deliver:
      "This reserves \(title) in step mode and starts its managed worker"
    case .complete:
      "This moves \(title) to Done"
    }
  }

  private var approvalGrantRefreshID: TaskBoardApprovalGrantRefreshID {
    let activeCanvas = workspace?.canvases.first { $0.canvasId == workspace?.activeCanvasId }
    return TaskBoardApprovalGrantRefreshID(
      heldIntentIDs: status.heldDispatches.items.map(\.intentId).sorted(),
      activeCanvasID: workspace?.activeCanvasId,
      activeRevision: activeCanvas?.liveDocument?.revision ?? activeCanvas?.revision,
      lastRunID: status.lastRun?.runId,
      evaluationFingerprint: approvalEvaluationFingerprint,
      localGeneration: state.approvalRefreshGeneration
    )
  }

  private var approvalEvaluationFingerprint: TaskBoardApprovalEvaluationFingerprint? {
    latestEvaluation.map { TaskBoardApprovalEvaluationFingerprint(evaluation: $0) }
  }
}
