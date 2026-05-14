import HarnessMonitorKit
import SwiftUI

struct TaskBoardOrchestratorSummaryView: View {
  let status: TaskBoardOrchestratorStatus
  let latestEvaluation: TaskBoardEvaluationSummary?
  let isActionInFlight: Bool
  let onStart: (() -> Void)?
  let onStop: (() -> Void)?
  let onRunOnce: (() -> Void)?
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardOverviewMetrics {
    TaskBoardOverviewMetrics(fontScale: fontScale)
  }

  init(
    status: TaskBoardOrchestratorStatus,
    latestEvaluation: TaskBoardEvaluationSummary? = nil,
    isActionInFlight: Bool = false,
    onStart: (() -> Void)? = nil,
    onStop: (() -> Void)? = nil,
    onRunOnce: (() -> Void)? = nil
  ) {
    self.status = status
    self.latestEvaluation = latestEvaluation
    self.isActionInFlight = isActionInFlight
    self.onStart = onStart
    self.onStop = onStop
    self.onRunOnce = onRunOnce
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: HarnessMonitorTheme.spacingMD) {
        summaryContent
        Spacer(minLength: HarnessMonitorTheme.spacingMD)
        controls
      }
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        summaryContent
        controls
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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
      if let latestEvaluation {
        evaluationPills(latestEvaluation)
      } else if let lastRun = status.lastRun {
        lastRunPills(lastRun)
      }
      ForEach(workflowCountSummaries) { item in
        summaryPill(
          workflowStatusTitle(for: item.status),
          "\(item.count)",
          tint: workflowStatusTint(for: item.status)
        )
      }
    }
  }

  private var controls: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        controlButtons
      }
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        controlButtons
      }
    }
  }

  @ViewBuilder private var controlButtons: some View {
    if status.running {
      if let onStop {
        Button {
          onStop()
        } label: {
          Label("Stop", systemImage: "stop.circle")
            .scaledFont(.caption.weight(.semibold))
        }
        .frame(minHeight: metrics.controlMinHeight)
        .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.danger)
        .controlSize(HarnessMonitorControlMetrics.compactControlSize)
        .disabled(isActionInFlight)
        .help("Stop task-board orchestrator")
        .accessibilityIdentifier("harness.task-board.orchestrator.stop")
      }
    } else if let onStart {
      Button {
        onStart()
      } label: {
        Label("Start", systemImage: "play.circle")
          .scaledFont(.caption.weight(.semibold))
      }
      .frame(minHeight: metrics.controlMinHeight)
      .harnessActionButtonStyle(variant: .prominent, tint: HarnessMonitorTheme.accent)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .disabled(isActionInFlight)
      .help("Start task-board orchestrator")
      .accessibilityIdentifier("harness.task-board.orchestrator.start")
    }

    if let onRunOnce {
      Button {
        onRunOnce()
      } label: {
        Label("Run Once", systemImage: "playpause")
          .scaledFont(.caption.weight(.semibold))
      }
      .frame(minHeight: metrics.controlMinHeight)
      .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .disabled(isActionInFlight)
      .help("Run one task-board orchestrator tick")
      .accessibilityIdentifier("harness.task-board.orchestrator.run-once")
    }
  }

  @ViewBuilder
  private func lastRunPills(_ run: TaskBoardOrchestratorRunSummary) -> some View {
    summaryPill("Last", lastRunTitle(for: run), tint: runStatusTint(for: run.status))
    let appliedCount = lastRunAppliedCount(for: run)
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
        .scaledFont(.caption)
      Text(value)
        .scaledFont(.caption.weight(.bold))
    }
    .foregroundStyle(tint ?? HarnessMonitorTheme.secondaryInk)
    .lineLimit(1)
    .harnessPillPadding()
    .harnessControlPill(tint: tint ?? HarnessMonitorTheme.secondaryInk)
  }

  private var stateTitle: String {
    if !status.enabled {
      return "Disabled"
    }
    if status.running {
      return "Running"
    }
    return "Idle"
  }

  private var stateTint: Color {
    if !status.enabled {
      return HarnessMonitorTheme.secondaryInk
    }
    if status.running {
      return HarnessMonitorTheme.accent
    }
    return HarnessMonitorTheme.caution
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

  private func lastRunAppliedCount(for run: TaskBoardOrchestratorRunSummary) -> Int {
    (run.dispatch?.applied.count ?? 0) + (run.evaluation?.updated ?? 0)
  }

  private var workflowCountSummaries: [TaskBoardWorkflowCountPresentation] {
    var totals: [TaskBoardWorkflowStatus: Int] = [:]
    for item in status.workflowExecutionCounts where item.count >= 1 {
      totals[item.status, default: 0] += item.count
    }
    return TaskBoardWorkflowStatus.allCases.compactMap { workflowStatus in
      guard let count = totals[workflowStatus], count >= 1 else {
        return nil
      }
      return TaskBoardWorkflowCountPresentation(status: workflowStatus, count: count)
    }
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

private struct TaskBoardWorkflowCountPresentation: Identifiable {
  let status: TaskBoardWorkflowStatus
  let count: Int

  var id: String { status.rawValue }
}
