import HarnessMonitorKit
import SwiftUI

struct TaskBoardOrchestratorPillsView: View {
  let status: TaskBoardOrchestratorStatus
  let presentation: TaskBoardOrchestratorPresentation

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      summaryPill("Status", stateTitle, tint: stateTint)
      if let currentTick = status.currentTick {
        summaryPill(
          "Tick",
          tickPhaseTitle(for: currentTick.phase),
          tint: tickPhaseTint(for: currentTick.phase)
        )
      }
      switch presentation.summarySource {
      case .lastRun(let lastRun, let appliedCount, let evaluation):
        lastRunPills(lastRun, appliedCount: appliedCount, evaluation: evaluation)
      case .standaloneEvaluation(let evaluation):
        evaluationPills(evaluation)
      case nil:
        EmptyView()
      }
      ForEach(presentation.workflowCounts) { item in
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

  @ViewBuilder
  private func lastRunPills(
    _ run: TaskBoardOrchestratorRunSummary,
    appliedCount: Int,
    evaluation: TaskBoardEvaluationPillPresentation?
  ) -> some View {
    summaryPill("Last", lastRunTitle(for: run), tint: runStatusTint(for: run.status))
    if appliedCount != 0 {
      summaryPill("Applied", "\(appliedCount)")
    }
    if let evaluation, evaluation.total != 0 || evaluation.evaluated != 0 {
      evaluationPills(evaluation)
    }
  }

  @ViewBuilder
  private func evaluationPills(_ evaluation: TaskBoardEvaluationPillPresentation) -> some View {
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
    let resolvedTint = tint ?? HarnessMonitorTheme.secondaryInk
    return TaskBoardSummaryPill(
      value: value,
      label: label,
      tint: resolvedTint,
      chrome: .control
    )
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
