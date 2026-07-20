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

  private var controlsDisabled: Bool {
    isActionInFlight || state.isBusy || store.contentUI.dashboard.connectionState != .online
  }

  private var primaryButtonFont: Font {
    HarnessMonitorTextSize.scaledFont(.callout.weight(.semibold), by: fontScale)
  }
  private var linkFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  var body: some View {
    TaskBoardSection(title: "Manual Steps") {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
        TaskBoardStepRailTargetView(item: activeItem, isPicked: stepFlow.hasPicked)
        Divider()
        TaskBoardStepProgressRail(
          current: stagePlan.column,
          isBlocked: stagePlan.isBlockedColumn,
          viewing: state.viewingColumn,
          state: state
        )
        cardArea
        contextDisclosure
      }
      .padding(HarnessMonitorTheme.spacingLG)
      .background(
        HarnessMonitorTheme.ink.opacity(0.025),
        in: .rect(cornerRadius: HarnessMonitorTheme.cornerRadiusMD)
      )
      .overlay {
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD)
          .strokeBorder(HarnessMonitorTheme.ink.opacity(0.10))
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
      switch cardPresentation {
      case .empty:
        emptyState
      case .preview(let column):
        previewCard(for: column)
      case .live:
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
      // The board chrome's Sync covers this too, but an empty state without a
      // way out is worse than the overlap.
      Button {
        state.presentConfirmation(.externalSync(itemID: activeItem?.id))
      } label: {
        Label("Sync external sources", systemImage: "arrow.triangle.2.circlepath")
      }
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      .disabled(controlsDisabled)
    }
    .frame(maxWidth: .infinity)
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
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        if plan.stage == .readyToDeliver, let selection = activeSelection {
          TaskBoardStepPromptPreview(prompt: selection.plan.renderedPrompt)
        }
        if !plan.inlineLinks.isEmpty {
          inlineLinksRow(plan.inlineLinks)
        }
        secondaryRow(plan)
      }
    }
  }

  /// Closing row of the stage card: whatever secondary controls this stage
  /// offers on the left, the primary Next action pinned to the right.
  private func secondaryRow(_ plan: TaskBoardStepStagePlan) -> some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
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
      Spacer(minLength: HarnessMonitorTheme.spacingMD)
      if let action = plan.primaryAction {
        primaryButton(action)
      }
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
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
    case .openTask: "list.bullet.rectangle"
    case .openPullRequest: "arrow.up.forward.square"
    }
  }

  func runPrimary(_ action: TaskBoardStepPrimaryAction) {
    switch action {
    case .sync:
      state.presentConfirmation(.externalSync(itemID: activeItem?.id))
    case .pick: enqueuePick()
    case .deliver:
      if let itemID = deliveryItemID {
        state.presentConfirmation(.deliver(itemID: itemID))
      }
    case .evaluate:
      if let itemID = activeItem?.id {
        state.presentConfirmation(.evaluate(itemID: itemID))
      }
    case .complete:
      if let itemID = activeItem?.id {
        state.presentConfirmation(.complete(itemID: itemID))
      }
    }
  }

  func runLink(_ link: TaskBoardStepInlineLink) {
    switch link {
    case .watch:
      openSpawnedAgent()
    case .openTask:
      openReview()
    case .openPullRequest:
      if let url = TaskBoardStepStageResolver.validURL(activeItem?.workflow?.prUrl) {
        openURL(url)
      }
    }
  }

  private var contextDisclosure: some View {
    TaskBoardStepContextDisclosure(
      store: store,
      workspace: workspace,
      heldDispatches: status.heldDispatches,
      refreshID: approvalGrantRefreshID,
      isDisabled: controlsDisabled,
      isExpanded: $state.isAutomationContextExpanded
    )
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
        runConfirmation(confirmation)
      }
      .disabled(controlsDisabled)
    case .evaluate:
      Button("Evaluate Live", role: .destructive) {
        runConfirmation(confirmation)
      }
      .disabled(controlsDisabled)
    case .deliver(let itemID):
      Button("Deliver Live", role: .destructive) {
        runConfirmation(confirmation)
      }
      .disabled(controlsDisabled || deliveryItemID != itemID)
    case .complete:
      Button("Complete", role: .destructive) {
        runConfirmation(confirmation)
      }
      .disabled(controlsDisabled)
    }
    Button("Cancel", role: .cancel) {}
  }

  func runConfirmation(_ confirmation: TaskBoardStepRailState.Confirmation) {
    state.confirmation = nil
    switch confirmation {
    case .externalSync(let itemID): enqueueExternalSync(itemID: itemID)
    case .evaluate(let itemID): enqueueEvaluation(itemID: itemID)
    case .deliver(let itemID): enqueueDelivery(itemID: itemID)
    case .complete(let itemID): enqueueCompletion(itemID: itemID)
    }
  }

  private func confirmationMessage(_ confirmation: TaskBoardStepRailState.Confirmation) -> String {
    let title =
      confirmation.itemID.flatMap { itemID in
        activeItem.flatMap { $0.id == itemID ? $0.title : nil }
      } ?? "the current item"
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
