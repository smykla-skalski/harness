import HarnessMonitorKit
import SwiftUI

struct TaskBoardOrchestratorSummaryView: View {
  let status: TaskBoardOrchestratorStatus
  let taskBoardItems: [TaskBoardItem]
  let localHostProjectTypes: [String]?
  let latestEvaluation: TaskBoardEvaluationSummary?
  let latestEvaluationBaselineRunID: String?
  let isActionInFlight: Bool
  let actions: TaskBoardOverviewActions
  @Binding var pendingLiveOperation: TaskBoardOverviewLiveOperation?
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardOverviewMetrics {
    TaskBoardOverviewMetrics(fontScale: fontScale)
  }
  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }
  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }
  private var captionBold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.bold), by: fontScale)
  }

  // Keep the expensive summary-vs-controls layout width-gated while action
  // buttons stay in a single row.
  @State private var bodyFitsHorizontally = true

  private var bodyHorizontalMinWidth: CGFloat { 640 }

  init(
    status: TaskBoardOrchestratorStatus,
    taskBoardItems: [TaskBoardItem] = [],
    localHostProjectTypes: [String]? = nil,
    latestEvaluation: TaskBoardEvaluationSummary? = nil,
    latestEvaluationBaselineRunID: String? = nil,
    isActionInFlight: Bool = false,
    actions: TaskBoardOverviewActions,
    pendingLiveOperation: Binding<TaskBoardOverviewLiveOperation?>
  ) {
    self.status = status
    self.taskBoardItems = taskBoardItems
    self.localHostProjectTypes = localHostProjectTypes
    self.latestEvaluation = latestEvaluation
    self.latestEvaluationBaselineRunID = latestEvaluationBaselineRunID
    self.isActionInFlight = isActionInFlight
    self.actions = actions
    _pendingLiveOperation = pendingLiveOperation
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Group {
        if bodyFitsHorizontally {
          HStack(spacing: HarnessMonitorTheme.spacingMD) {
            summaryContent
            Spacer(minLength: HarnessMonitorTheme.spacingMD)
            controls
          }
        } else {
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
            summaryContent
            controls
          }
        }
      }
      if let lastRun = status.lastRun {
        TaskBoardOrchestratorRunDetailsView(run: lastRun)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      let next = width >= bodyHorizontalMinWidth
      if bodyFitsHorizontally != next {
        bodyFitsHorizontally = next
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.orchestrator-summary")
  }

  private var summaryContent: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      summaryPill("Status", stateTitle, tint: stateTint)
      if let currentTick = status.currentTick {
        summaryPill(
          "Tick",
          tickPhaseTitle(for: currentTick.phase),
          tint: tickPhaseTint(for: currentTick.phase)
        )
      }
      switch orchestratorPresentation.summarySource(
        latestEvaluation: latestEvaluation,
        baselineRunID: latestEvaluationBaselineRunID
      ) {
      case .lastRun(let lastRun):
        lastRunPills(lastRun)
      case .standaloneEvaluation(let evaluation):
        evaluationPills(evaluation)
      case nil:
        EmptyView()
      }
      ForEach(workflowCountSummaries) { item in
        summaryPill(
          workflowStatusTitle(for: item.status),
          "\(item.count)",
          tint: workflowStatusTint(for: item.status)
        )
      }
      if !status.heldDispatches.items.isEmpty {
        summaryPill("Held", "\(status.heldDispatches.count)", tint: HarnessMonitorTheme.caution)
      }
    }
  }

  private var controls: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      controlButtons
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  @ViewBuilder private var controlButtons: some View {
    if actions.canSetStepMode {
      Toggle(
        "Step Mode",
        isOn: Binding(
          get: { status.stepMode },
          set: { enabled in actions.setTaskBoardStepMode(enabled) }
        )
      )
      .toggleStyle(.switch)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .disabled(isActionInFlight)
      .help("Pause the continuous loop and expose manual task-board stages")
      .accessibilityIdentifier("harness.task-board.orchestrator.step-mode")
    }

    if status.running {
      if actions.canStopOrchestrator {
        Button {
          actions.stopTaskBoardOrchestrator()
        } label: {
          Label("Stop", systemImage: "stop.circle")
            .font(captionSemibold)
        }
        .frame(minHeight: metrics.controlMinHeight)
        .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.danger)
        .controlSize(HarnessMonitorControlMetrics.compactControlSize)
        .disabled(isActionInFlight)
        .help("Stop task-board orchestrator")
        .accessibilityIdentifier("harness.task-board.orchestrator.stop")
      }
    } else if actions.canStartOrchestrator {
      Button {
        actions.startTaskBoardOrchestrator()
      } label: {
        Label("Start", systemImage: "play.circle")
          .font(captionSemibold)
      }
      .frame(minHeight: metrics.controlMinHeight)
      .harnessActionButtonStyle(variant: .prominent, tint: HarnessMonitorTheme.accent)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .disabled(isActionInFlight)
      .help("Start task-board orchestrator")
      .accessibilityIdentifier("harness.task-board.orchestrator.start")
    }

    if actions.canRunOrchestratorOnce {
      Button {
        triggerRunOnce()
      } label: {
        Label(runOnceTitle, systemImage: "playpause")
          .font(captionSemibold)
      }
      .frame(minHeight: metrics.controlMinHeight)
      .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .disabled(isActionInFlight)
      .help(runOnceHelp)
      .accessibilityIdentifier("harness.task-board.orchestrator.run-once")
    }
  }

  /// Mirrors `TaskBoardOverviewView.requestRunOnce`: dry runs apply directly,
  /// live runs route through the shared confirmation dialog.
  private func triggerRunOnce() {
    let request = TaskBoardOrchestratorRunOnceRequest(dryRun: status.settings.dryRunDefault)
    guard request.dryRun != true else {
      actions.runTaskBoardOrchestratorOnce(request)
      return
    }
    pendingLiveOperation = .runOnce(request)
  }

  @ViewBuilder
  private func lastRunPills(_ run: TaskBoardOrchestratorRunSummary) -> some View {
    summaryPill("Last", lastRunTitle(for: run), tint: runStatusTint(for: run.status))
    let appliedCount = TaskBoardOrchestratorPresentation.appliedItemCount(for: run)
    if appliedCount != 0 {
      summaryPill("Applied", "\(appliedCount)")
    }
    if let evaluation = run.evaluation, evaluation.total != 0 || evaluation.evaluated != 0 {
      evaluationPills(evaluation)
    }
  }

  @ViewBuilder
  private func evaluationPills(_ evaluation: TaskBoardEvaluationSummary) -> some View {
    summaryPill("Eval", "\(evaluation.evaluated)/\(evaluation.total)")
    if evaluation.updated != 0 {
      summaryPill("Updated", "\(evaluation.updated)", tint: HarnessMonitorTheme.accent)
    }
    if evaluation.failed != 0 || evaluation.blocked != 0 {
      summaryPill(
        "Blocked",
        "\(evaluation.failed + evaluation.blocked)",
        tint: HarnessMonitorTheme.danger
      )
    }
  }

  private func summaryPill(_ label: String, _ value: String, tint: Color? = nil) -> some View {
    HStack(spacing: 4) {
      Text(label)
        .font(captionFont)
      Text(value)
        .font(captionBold)
    }
    .foregroundStyle(tint ?? HarnessMonitorTheme.secondaryInk)
    .lineLimit(1)
    .harnessPillPadding()
    .harnessControlPill(tint: tint ?? HarnessMonitorTheme.secondaryInk)
  }

  private var stateTitle: String {
    TaskBoardOrchestratorPresentation.stateTitle(for: status)
  }

  private var stateTint: Color {
    if status.stepMode {
      return HarnessMonitorTheme.caution
    }
    if !status.enabled {
      return HarnessMonitorTheme.secondaryInk
    }
    if status.running {
      return HarnessMonitorTheme.accent
    }
    return HarnessMonitorTheme.caution
  }

  private var runOnceTitle: String {
    status.settings.dryRunDefault ? "Preview Run Once" : "Run Once Live"
  }

  private var runOnceHelp: String {
    status.settings.dryRunDefault
      ? "Preview one orchestrator cycle without applying changes"
      : "Run one live orchestrator cycle and apply changes"
  }

  private func lastRunTitle(for run: TaskBoardOrchestratorRunSummary) -> String {
    let mode = run.dryRun ? "Dry" : "Live"
    return "\(runStatusTitle(for: run.status)) \(mode)"
  }

  private func runStatusTitle(for status: TaskBoardOrchestratorRunStatus) -> String {
    switch status {
    case .completed:
      "Completed"
    case .failed:
      "Failed"
    }
  }

  private func runStatusTint(for status: TaskBoardOrchestratorRunStatus) -> Color {
    switch status {
    case .completed:
      HarnessMonitorTheme.accent
    case .failed:
      HarnessMonitorTheme.danger
    }
  }

  private func tickPhaseTitle(for phase: TaskBoardOrchestratorTickPhase) -> String {
    switch phase {
    case .starting:
      "Starting"
    case .dispatch:
      "Dispatch"
    case .evaluation:
      "Evaluate"
    case .completed:
      "Completed"
    case .failed:
      "Failed"
    }
  }

  private func tickPhaseTint(for phase: TaskBoardOrchestratorTickPhase) -> Color {
    switch phase {
    case .failed:
      HarnessMonitorTheme.danger
    case .starting, .dispatch, .evaluation, .completed:
      HarnessMonitorTheme.accent
    }
  }

  private var workflowCountSummaries: [TaskBoardWorkflowCountPresentation] {
    orchestratorPresentation.workflowCounts
  }

  private var orchestratorPresentation: TaskBoardOrchestratorPresentation {
    TaskBoardOrchestratorPresentation(
      status: status,
      taskBoardItems: taskBoardItems,
      localHostProjectTypes: localHostProjectTypes
    )
  }

  private func workflowStatusTitle(for status: TaskBoardWorkflowStatus) -> String {
    switch status {
    case .idle:
      "Idle"
    case .running:
      "Running"
    case .paused:
      "Paused"
    case .completed:
      "Done"
    case .failed:
      "Failed"
    case .cancelled:
      "Canceled"
    }
  }

  private func workflowStatusTint(for status: TaskBoardWorkflowStatus) -> Color {
    switch status {
    case .running:
      HarnessMonitorTheme.accent
    case .paused:
      HarnessMonitorTheme.caution
    case .failed, .cancelled:
      HarnessMonitorTheme.danger
    case .completed:
      HarnessMonitorTheme.secondaryInk
    case .idle:
      HarnessMonitorTheme.tertiaryInk
    }
  }
}
