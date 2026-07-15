import HarnessMonitorKit
import SwiftUI

extension TaskBoardOverviewView {
  @ViewBuilder var boardChrome: some View {
    if hasRouteContent || store != nil {
      if taskBoardSessionID == nil, let orchestratorStatus {
        taskBoardDetailRow {
          TaskBoardOrchestratorSummaryView(
            status: orchestratorStatus,
            taskBoardItems: currentPresentation.taskBoardItems,
            localHostProjectTypes: localHostRoutingStateValue.projectTypes,
            latestEvaluation: evaluationSummary,
            latestEvaluationBaselineRunID: store?.contentUI.dashboard
              .taskBoardEvaluationBaselineRunID,
            isActionInFlight: isActionInFlight,
            onStart: onStartTaskBoardOrchestrator,
            onStop: onStopTaskBoardOrchestrator,
            onRunOnce: runOrchestratorOnce,
            onStepModeChange: onSetTaskBoardStepMode
          )
        }
      } else if let evaluationSummary {
        taskBoardDetailRow { evaluationSummaryRow(evaluationSummary) }
      }
    }
    if let orchestratorStatus,
      TaskBoardOrchestratorPresentation.showsManualSteps(
        for: orchestratorStatus,
        scopeSessionID: taskBoardSessionID,
        hasStore: store != nil
      ),
      let store
    {
      taskBoardDetailRow {
        TaskBoardStepRailView(
          store: store,
          status: orchestratorStatus,
          latestEvaluation: evaluationSummary,
          workspace: store.contentUI.dashboard.policyCanvasWorkspace,
          targetItem: stepRailTargetItem,
          isActionInFlight: isActionInFlight,
          onOpenReview: onOpenTaskBoardItem
        )
      }
    }
    if let evaluatePreviewSummaryValue {
      taskBoardDetailRow { evaluatePreviewRow(evaluatePreviewSummaryValue) }
    }
    taskBoardDetailRow { headerTitle }
    if taskBoardSessionID == nil, showsOperationsPanel, let store {
      taskBoardDetailRow {
        TaskBoardOperationsPanel(store: store, taskBoardItems: currentPresentation.taskBoardItems)
      }
    }
  }

  var headerTitle: some View {
    Label("Board", systemImage: "rectangle.3.group")
      .font(titleHeaderFont)
      .accessibilityAddTraits(.isHeader)
  }

  var headerActions: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      headerActionButtons
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  var boardAccessoryRow: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingMD) {
      if hasAggregateSummary {
        aggregateSummaryRow
      }
      if hasAggregateSummary && hasHeaderActions {
        Spacer(minLength: HarnessMonitorTheme.spacingMD)
      }
      if hasHeaderActions {
        headerActions
      }
    }
  }

  var hasHeaderActions: Bool {
    onCreateTaskBoardItem != nil || onEvaluateTaskBoard != nil || onRefreshTaskBoard != nil
  }

  @ViewBuilder var headerActionButtons: some View {
    if onCreateTaskBoardItem != nil {
      Button {
        startTaskBoardItemCreation()
      } label: {
        Label("New Item", systemImage: "plus.circle")
          .font(captionSemibold)
      }
      .frame(minHeight: metrics.controlMinHeight)
      .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .disabled(isActionInFlight)
      .help("Create board item")
      .accessibilityIdentifier("harness.task-board.new-item")
    }

    if onEvaluateTaskBoard != nil {
      if store != nil {
        Toggle("Dry run", isOn: $evaluateDryRun)
          .toggleStyle(.checkbox)
          .controlSize(HarnessMonitorControlMetrics.compactControlSize)
          .disabled(isActionInFlight)
          .help("Preview the evaluate without applying any board changes")
          .accessibilityIdentifier("harness.task-board.evaluate.dry-run")
      }
      Button {
        triggerBoardEvaluate()
      } label: {
        Label(
          evaluateDryRun ? "Preview Evaluate" : "Evaluate Live",
          systemImage: "checkmark.seal"
        )
        .font(captionSemibold)
      }
      .frame(minHeight: metrics.controlMinHeight)
      .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .disabled(isActionInFlight)
      .help(
        evaluateDryRun
          ? "Preview evaluate results without applying changes"
          : "Evaluate and apply live board transitions after confirmation"
      )
      .accessibilityIdentifier("harness.task-board.evaluate")
    }

    if let onRefreshTaskBoard {
      Button {
        onRefreshTaskBoard()
      } label: {
        Label("Sync", systemImage: "arrow.clockwise")
          .font(captionSemibold)
      }
      .frame(minHeight: metrics.controlMinHeight)
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .disabled(isActionInFlight)
      .help("Pull external sources and apply changes to the task board")
      .accessibilityIdentifier("harness.task-board.refresh")
    }
  }

  var aggregateSummaryRow: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      aggregateSummaryContent
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  var hasBoardContent: Bool {
    currentPresentation.hasBoardContent
  }

  var stepRailTargetItem: TaskBoardItem? {
    for cardID in orderedSelectedCardIDs {
      guard case .api(let itemID) = cardID else { continue }
      if let item = currentPresentation.taskBoardItem(id: itemID) {
        return item
      }
    }
    return currentPresentation.apiItems(in: .todo).first
  }

  var boardSection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      if hasAggregateSummary || hasHeaderActions {
        boardAccessoryRow
      }
      boardContent
        .frame(maxHeight: fillsAvailableHeight ? .infinity : nil)
    }
    .frame(maxHeight: fillsAvailableHeight ? .infinity : nil)
  }
}
