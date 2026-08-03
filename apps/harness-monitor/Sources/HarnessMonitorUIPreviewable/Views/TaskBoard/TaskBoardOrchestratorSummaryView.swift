import HarnessMonitorKit
import SwiftUI

struct TaskBoardOrchestratorSummaryView: View {
  let status: TaskBoardOrchestratorStatus
  let taskBoardItems: [TaskBoardItem]
  let localHostProjectTypes: [String]?
  let preparedPresentation: TaskBoardOrchestratorPresentation?
  let latestEvaluation: TaskBoardEvaluationSummary?
  let latestEvaluationBaselineRunID: String?
  let isActionInFlight: Bool
  let isRunOnceInFlight: Bool
  let actions: TaskBoardOverviewActions
  @Binding var pendingLiveOperation: TaskBoardOverviewLiveOperation?
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardOverviewMetrics {
    TaskBoardOverviewMetrics(fontScale: fontScale)
  }
  // Keep the expensive summary-vs-controls layout width-gated while action
  // buttons stay in a single row.
  @State private var bodyFitsHorizontally = true

  private var bodyHorizontalMinWidth: CGFloat { 640 }

  init(
    status: TaskBoardOrchestratorStatus,
    taskBoardItems: [TaskBoardItem] = [],
    localHostProjectTypes: [String]? = nil,
    presentation: TaskBoardOrchestratorPresentation? = nil,
    latestEvaluation: TaskBoardEvaluationSummary? = nil,
    latestEvaluationBaselineRunID: String? = nil,
    isActionInFlight: Bool = false,
    isRunOnceInFlight: Bool = false,
    actions: TaskBoardOverviewActions,
    pendingLiveOperation: Binding<TaskBoardOverviewLiveOperation?>
  ) {
    self.status = status
    self.taskBoardItems = taskBoardItems
    self.localHostProjectTypes = localHostProjectTypes
    preparedPresentation = presentation
    self.latestEvaluation = latestEvaluation
    self.latestEvaluationBaselineRunID = latestEvaluationBaselineRunID
    self.isActionInFlight = isActionInFlight
    self.isRunOnceInFlight = isRunOnceInFlight
    self.actions = actions
    _pendingLiveOperation = pendingLiveOperation
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Group {
        if bodyFitsHorizontally {
          HStack(spacing: HarnessMonitorTheme.spacingMD) {
            TaskBoardOrchestratorPillsView(
              status: status,
              presentation: orchestratorPresentation
            )
            Spacer(minLength: HarnessMonitorTheme.spacingMD)
            controls
          }
        } else {
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
            TaskBoardOrchestratorPillsView(
              status: status,
              presentation: orchestratorPresentation
            )
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

  private var controls: some View {
    TaskBoardOrchestratorControls(
      status: status,
      isActionInFlight: isActionInFlight,
      isRunOnceInFlight: isRunOnceInFlight,
      actions: actions,
      pendingLiveOperation: $pendingLiveOperation
    )
  }

  private var orchestratorPresentation: TaskBoardOrchestratorPresentation {
    preparedPresentation
      ?? TaskBoardOrchestratorPresentation(
        status: status,
        taskBoardItems: taskBoardItems,
        localHostProjectTypes: localHostProjectTypes,
        latestEvaluation: latestEvaluation,
        latestEvaluationBaselineRunID: latestEvaluationBaselineRunID
      )
  }
}
