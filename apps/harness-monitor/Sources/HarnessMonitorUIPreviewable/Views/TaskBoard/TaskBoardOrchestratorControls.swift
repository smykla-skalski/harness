import HarnessMonitorKit
import SwiftUI

struct TaskBoardOrchestratorControls: View {
  let status: TaskBoardOrchestratorStatus
  let isActionInFlight: Bool
  let isRunOnceInFlight: Bool
  let actions: TaskBoardOverviewActions
  @Binding var pendingLiveOperation: TaskBoardOverviewLiveOperation?
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardOverviewMetrics {
    TaskBoardOverviewMetrics(fontScale: fontScale)
  }

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
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

    if actions.canSetDryRun {
      Toggle(
        "Dry Run",
        isOn: Binding(
          get: { status.settings.dryRunDefault },
          set: { enabled in actions.setTaskBoardDryRun(enabled) }
        )
      )
      .toggleStyle(.switch)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .disabled(isActionInFlight)
      .help("Preview task-board runs and evaluations without applying changes")
      .accessibilityIdentifier("harness.task-board.orchestrator.dry-run")
    }

    if status.running || hasActiveRun {
      if actions.canStopOrchestrator {
        stopButton
      }
    } else if actions.canStartOrchestrator {
      startButton
    }

    if actions.canRunOrchestratorOnce {
      runOnceButton
    }
  }

  private var stopButton: some View {
    Button {
      actions.stopTaskBoardOrchestrator()
    } label: {
      Label("Stop", systemImage: "stop.circle")
        .font(captionSemibold)
    }
    .frame(minHeight: metrics.controlMinHeight)
    .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.danger)
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
    .disabled(!isControlOnline)
    .help(
      hasActiveRun
        ? "Cancel the active run and stop task-board automation"
        : "Stop task-board orchestrator"
    )
    .accessibilityIdentifier("harness.task-board.orchestrator.stop")
  }

  private var startButton: some View {
    Button {
      triggerStart()
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

  private var runOnceButton: some View {
    Button {
      triggerRunOnce()
    } label: {
      Label("Run Once", systemImage: "playpause")
        .font(captionSemibold)
    }
    .frame(minHeight: metrics.controlMinHeight)
    .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
    .disabled(isActionInFlight)
    .help(runOnceHelp)
    .accessibilityIdentifier("harness.task-board.orchestrator.run-once")
  }

  private var hasActiveRun: Bool {
    isRunOnceInFlight
      || status.automation?.activeRun != nil
      || actions.store?.contentUI.dashboard.taskBoardAutomationSnapshot?.activeRun != nil
  }

  private var isControlOnline: Bool {
    actions.store?.contentUI.dashboard.connectionState == .online
  }

  private var runOnceHelp: String {
    status.settings.dryRunDefault
      ? "Preview one orchestrator cycle without applying changes"
      : "Run one live orchestrator cycle and apply changes"
  }

  private func triggerStart() {
    guard !status.settings.dryRunDefault else {
      actions.startTaskBoardOrchestrator()
      return
    }
    pendingLiveOperation = .start(status.settings.scheduling)
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
}
