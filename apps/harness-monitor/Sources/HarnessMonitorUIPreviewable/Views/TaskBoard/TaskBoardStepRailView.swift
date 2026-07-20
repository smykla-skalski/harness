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
  // Deterministic if/else on a measured width rather than ViewThatFits, which
  // would build both candidate trees on every update.
  @State private var showsRailTitles = true

  var stepRailState: TaskBoardStepRailState { state }

  // Not private: the confirmation dialog lives in a companion file.
  var controlsDisabled: Bool {
    isActionInFlight || state.isBusy || store.contentUI.dashboard.connectionState != .online
  }

  /// Below this the rail titles crowd the detail column, so the track drops to
  /// badges and keeps its meaning in tooltips and accessibility labels.
  private static let railTitleMinWidth: CGFloat = 480

  private var railWidth: CGFloat {
    let scale = min(SessionWindowFontScale.metricsScale(for: fontScale), 1.4)
    return showsRailTitles
      ? 132 * scale
      : TaskBoardStepProgressRail.badgeSide(for: fontScale)
  }

  /// The panel stops growing well before the board column does. Left to fill an
  /// ultra-wide display it ran body copy past a hundred characters a line and
  /// stranded the primary button an arm's length from the text it acts on.
  private var panelMaxWidth: CGFloat {
    840 * min(SessionWindowFontScale.metricsScale(for: fontScale), 1.5)
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
        stageSplit
        Divider()
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
      .frame(maxWidth: panelMaxWidth, alignment: .leading)
      // The cap only bounds the panel; this pins the bounded panel to the
      // leading edge instead of letting the container centre it.
      .frame(maxWidth: .infinity, alignment: .leading)
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

  /// The lifecycle track on the left, the stage it points at on the right. One
  /// panel with a divider rather than two surfaces: the rail selects and the
  /// detail displays, so they read as a single control.
  private var stageSplit: some View {
    HStack(alignment: .top, spacing: splitGutter * 2) {
      TaskBoardStepProgressRail(
        current: stagePlan.column,
        isBlocked: stagePlan.isBlockedColumn,
        viewing: state.viewingColumn,
        state: state,
        showsTitles: showsRailTitles
      )
      .frame(width: railWidth)
      cardArea
    }
    // The separator is an overlay, not a Divider sitting between the columns: a
    // Divider is flexible along the stack's cross axis, so as a sibling it made
    // the split greedy and stretched the panel down the whole window.
    .overlay(alignment: .leading) { columnSeparator }
    // The detail column fills the stack so its Spacer can bottom-align the
    // action row against the rail. That makes the column vertically flexible,
    // and pinning the split to its ideal height stops the flexibility from
    // propagating up and stretching the panel down the window again. The ideal
    // is max(rail, detail), which SwiftUI derives - do not reintroduce a
    // hand-computed rail height here, it only drifts from the real layout.
    .fixedSize(horizontal: false, vertical: true)
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      let next = width >= Self.railTitleMinWidth
      if showsRailTitles != next {
        showsRailTitles = next
      }
    }
  }

  /// Clear space on either side of the column separator. Matches the vertical
  /// gap the panel's VStack leaves under the header rule, so the detail title is
  /// inset from the separator by exactly what it is inset from the rule above.
  private var splitGutter: CGFloat { HarnessMonitorTheme.spacingLG }

  private var columnSeparator: some View {
    Rectangle()
      .fill(HarnessMonitorTheme.ink.opacity(0.10))
      .frame(width: 1)
      .padding(.leading, railWidth + splitGutter)
      // Decorative: it rides above both columns, so leave clicks and VoiceOver
      // to the controls underneath.
      .allowsHitTesting(false)
      .accessibilityHidden(true)
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
    // Fills the split both ways: the width so copy uses the column, the height
    // so the stage detail's Spacer has slack to push its actions onto the
    // rail's bottom edge. Height only fills what the split resolved to.
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
    TaskBoardStepStageDetail(
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
    TaskBoardStepStageDetail(
      stageTitle: plan.stage.title,
      whatHappened: plan.whatHappened,
      whatNext: plan.whatNext
    ) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        if plan.stage == .readyToDeliver, let selection = activeSelection {
          TaskBoardStepPromptPreview(prompt: selection.plan.renderedPrompt)
        }
        if offersActions(plan) {
          actionRow(plan)
        }
      }
    }
  }

  /// Whether the stage offers any control at all. Without the guard the row
  /// still renders as a lone Spacer and the stack spends a gap on it, which
  /// shows up at `.readyToDeliver` when a held delivery cannot be retried:
  /// no primary action, and this stage carries no inline links.
  private func offersActions(_ plan: TaskBoardStepStagePlan) -> Bool {
    plan.primaryAction != nil || !plan.inlineLinks.isEmpty || plan.stage == .done
  }

  /// Closing row of the detail column: navigation links on the leading edge,
  /// the stage's primary control on the trailing edge, centred against each
  /// other so the small links sit level with the large button. The two trailing
  /// branches are mutually exclusive on `primaryAction`, so whichever control
  /// this stage offers lands in the same corner.
  private func actionRow(_ plan: TaskBoardStepStagePlan) -> some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
      if !plan.inlineLinks.isEmpty {
        inlineLinksRow(plan.inlineLinks)
      }
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      if plan.stage == .done, plan.primaryAction == nil {
        startNextItemButton
      }
      if let action = plan.primaryAction {
        primaryButton(action)
      }
    }
  }

  private var startNextItemButton: some View {
    Button {
      state.resetFlow()
    } label: {
      Label("Start next item", systemImage: "forward.end").font(linkFont)
    }
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .controlSize(.small)
    .accessibilityIdentifier("harness.task-board.step.start-next")
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
