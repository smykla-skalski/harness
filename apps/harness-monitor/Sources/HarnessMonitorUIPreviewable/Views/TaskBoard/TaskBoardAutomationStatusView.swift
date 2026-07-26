import SwiftUI

enum TaskBoardAutomationStatusContentMode: Equatable {
  case loading
  case waiting
  case presentation

  static func resolve(
    presentation: TaskBoardAutomationPresentation,
    isPresentationCurrent: Bool
  ) -> Self {
    // Keep cached rows mounted during push rebuilds so inspector scroll geometry cannot collapse.
    guard presentation.statePills.isEmpty else { return .presentation }
    return isPresentationCurrent ? .waiting : .loading
  }
}

struct TaskBoardAutomationStatusView: View {
  let presentation: TaskBoardAutomationPresentation
  let metrics: TaskBoardOverviewMetrics
  let isPresentationCurrent: Bool

  private var contentMode: TaskBoardAutomationStatusContentMode {
    .resolve(
      presentation: presentation,
      isPresentationCurrent: isPresentationCurrent
    )
  }

  var body: some View {
    TaskBoardOperationsCard(
      title: "Automation status",
      metrics: metrics,
      background: presentation.isDegraded ? .warning : .standard
    ) {
      switch contentMode {
      case .loading:
        TaskBoardAutomationPlaceholder(
          title: "Loading automation status…",
          systemImage: "arrow.triangle.2.circlepath",
          showsProgress: true
        )
      case .waiting:
        TaskBoardAutomationPlaceholder(
          title: "Waiting for the compact automation push snapshot",
          systemImage: "dot.radiowaves.left.and.right"
        )
      case .presentation:
        statusPresentation
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.automation.status")
  }

  @ViewBuilder private var statusPresentation: some View {
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
