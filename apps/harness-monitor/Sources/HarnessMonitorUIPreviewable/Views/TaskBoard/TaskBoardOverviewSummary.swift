import HarnessMonitorKit
import SwiftUI

extension TaskBoardOverviewView {
  var taskBoardReviewCount: Int {
    currentPresentation.apiItems(in: .agenticReview).count
      + currentPresentation.apiItems(in: .testing).count
      + currentPresentation.apiItems(in: .inReview).count
      + currentPresentation.apiItems(in: .toReview).count
  }

  var taskBoardNeedsYouCount: Int {
    currentPresentation.apiItems(in: .humanRequired).count
  }

  var taskBoardBlockedCount: Int {
    currentPresentation.apiItems(in: .failed).count
  }

  var taskBoardDoneCount: Int {
    currentPresentation.aggregateDoneCount
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
        label: "Human Required",
        systemImage: TaskBoardInboxLane.humanRequired.systemImage,
        tint: taskBoardLaneColor(for: .humanRequired)
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
        systemImage: TaskBoardInboxLane.inReview.systemImage,
        tint: taskBoardLaneColor(for: .inReview)
      )
    }
    if aggregateBlockedCount != 0 {
      TaskBoardSummaryPill(
        value: "\(aggregateBlockedCount)",
        label: "Failed",
        systemImage: TaskBoardInboxLane.failed.systemImage,
        tint: taskBoardLaneColor(for: .failed)
      )
    }
    if aggregateDoneCount != 0 {
      TaskBoardSummaryPill(
        value: "\(aggregateDoneCount)",
        label: "Done",
        systemImage: "checkmark.circle",
        tint: HarnessMonitorTheme.secondaryInk
      )
    }
  }

  /// Routes the board-level Evaluate action: a live evaluate goes through the
  /// host closure (applies changes, updates the persisted summary), while a
  /// dry run reads counts into a local preview strip without mutating state.
  func triggerBoardEvaluate(_ liveEvaluate: @escaping () -> Void) {
    guard evaluateDryRun, let store else {
      evaluatePreviewSummaryValue = nil
      liveEvaluate()
      return
    }
    let previewState = evaluatePreviewStateValue
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Previewing task-board evaluate") {
        let summary = await store.previewEvaluateTaskBoard()
        await MainActor.run {
          previewState.summary = summary
        }
      }
    )
  }

  func evaluatePreviewRow(_ summary: TaskBoardEvaluationSummary) -> some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      TaskBoardSummaryPill(
        value: "Preview",
        label: "Dry Run",
        systemImage: "eye",
        tint: HarnessMonitorTheme.caution
      )
      evaluationSummaryContent(summary)
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      Button {
        evaluatePreviewSummaryValue = nil
      } label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.secondary)
          .contentShape(.circle)
          .accessibilityHidden(true)
      }
      .harnessDismissButtonStyle()
      .help("Dismiss the evaluate preview")
      .accessibilityLabel("Dismiss preview")
      .accessibilityIdentifier("harness.task-board.evaluate.preview.dismiss")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.evaluate.preview")
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
        label: "Failed",
        systemImage: TaskBoardInboxLane.failed.systemImage,
        tint: HarnessMonitorTheme.danger
      )
    }
  }
}

@MainActor
@Observable
final class TaskBoardEvaluatePreviewState {
  var summary: TaskBoardEvaluationSummary?
}
