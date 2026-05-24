import HarnessMonitorKit
import SwiftUI

extension TaskBoardOverviewView {
  var taskBoardReviewCount: Int {
    currentPresentation.apiItems(in: .review).count
  }

  var taskBoardNeedsYouCount: Int {
    currentPresentation.apiItems(in: .needsYou).count
  }

  var taskBoardBlockedCount: Int {
    currentPresentation.apiItems(in: .blocked).count
  }

  var taskBoardDoneCount: Int {
    currentPresentation.apiItems(in: .done).count
  }

  var aggregateNeedsYouCount: Int {
    currentPresentation.aggregateNeedsYouCount
  }

  var aggregateOpenCount: Int {
    currentPresentation.aggregateOpenCount
  }

  var aggregateReviewCount: Int {
    currentPresentation.aggregateReviewCount
  }

  var aggregateBlockedCount: Int {
    currentPresentation.aggregateBlockedCount
  }

  var aggregateDoneCount: Int {
    currentPresentation.aggregateDoneCount
  }

  var hasAggregateSummary: Bool {
    currentPresentation.hasAggregateSummary
  }

  @ViewBuilder var aggregateSummaryContent: some View {
    if aggregateNeedsYouCount != 0 {
      TaskBoardSummaryPill(
        value: "\(aggregateNeedsYouCount)",
        label: "Needs You",
        systemImage: TaskBoardInboxLane.needsYou.systemImage,
        tint: taskBoardLaneColor(for: .needsYou)
      )
    }
    if aggregateOpenCount != 0 {
      TaskBoardSummaryPill(
        value: "\(aggregateOpenCount)",
        label: "Open",
        systemImage: "rectangle.stack",
        tint: HarnessMonitorTheme.secondaryInk
      )
    }
    if aggregateReviewCount != 0 {
      TaskBoardSummaryPill(
        value: "\(aggregateReviewCount)",
        label: "Review",
        systemImage: TaskBoardInboxLane.review.systemImage,
        tint: taskBoardLaneColor(for: .review)
      )
    }
    if aggregateBlockedCount != 0 {
      TaskBoardSummaryPill(
        value: "\(aggregateBlockedCount)",
        label: "Blocked",
        systemImage: TaskBoardInboxLane.blocked.systemImage,
        tint: taskBoardLaneColor(for: .blocked)
      )
    }
    if aggregateDoneCount != 0 {
      TaskBoardSummaryPill(
        value: "\(aggregateDoneCount)",
        label: "Done",
        systemImage: TaskBoardInboxLane.done.systemImage,
        tint: taskBoardLaneColor(for: .done)
      )
    }
  }

  @ViewBuilder
  func evaluationSummaryContent(_ summary: TaskBoardEvaluationSummary) -> some View {
    TaskBoardSummaryPill(
      value: "\(summary.evaluated)/\(summary.total)",
      label: "Evaluated",
      systemImage: "checkmark.seal",
      tint: HarnessMonitorTheme.secondaryInk
    )
    if summary.updated != 0 {
      TaskBoardSummaryPill(
        value: "\(summary.updated)",
        label: "Updated",
        systemImage: "arrow.triangle.2.circlepath",
        tint: HarnessMonitorTheme.accent
      )
    }
    if summary.failed + summary.blocked != 0 {
      TaskBoardSummaryPill(
        value: "\(summary.failed + summary.blocked)",
        label: "Blocked",
        systemImage: TaskBoardInboxLane.blocked.systemImage,
        tint: HarnessMonitorTheme.danger
      )
    }
  }
}
