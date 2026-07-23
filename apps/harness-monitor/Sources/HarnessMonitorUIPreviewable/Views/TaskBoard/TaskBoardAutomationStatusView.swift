import SwiftUI

struct TaskBoardAutomationStatusView: View {
  let presentation: TaskBoardAutomationPresentation
  let metrics: TaskBoardOverviewMetrics
  let isPresentationCurrent: Bool

  var body: some View {
    TaskBoardOperationsCard(
      title: "Automation status",
      metrics: metrics,
      background: presentation.isDegraded ? .warning : .standard
    ) {
      if !isPresentationCurrent {
        TaskBoardAutomationPlaceholder(
          title: "Updating automation status…",
          systemImage: "arrow.triangle.2.circlepath",
          showsProgress: true
        )
      } else if presentation.statePills.isEmpty {
        TaskBoardAutomationPlaceholder(
          title: "Waiting for the compact automation push snapshot",
          systemImage: "dot.radiowaves.left.and.right"
        )
      } else {
        TaskBoardAutomationPillFlow(pills: presentation.statePills)

        TaskBoardAutomationSubsectionHeader(title: "Queue")
        TaskBoardAutomationPillFlow(pills: presentation.queuePills)

        TaskBoardAutomationSubsectionHeader(title: "Active run")
        if presentation.activeRunRows.isEmpty {
          TaskBoardAutomationPlaceholder(
            title: "No active automation run",
            systemImage: "pause.circle"
          )
        } else {
          TaskBoardAutomationValueRows(rows: presentation.activeRunRows)
        }

        TaskBoardAutomationSubsectionHeader(title: "Schedule and provider backoff")
        TaskBoardAutomationValueRows(rows: presentation.timingRows)

        TaskBoardAutomationSubsectionHeader(title: "Revisions")
        TaskBoardAutomationValueRows(rows: presentation.revisionRows)

        TaskBoardAutomationSubsectionHeader(title: "Health")
        TaskBoardAutomationValueRows(rows: presentation.issueRows)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.automation.status")
  }
}
