import HarnessMonitorKit
import SwiftUI

private struct TaskBoardReviewHeaderStatus {
  let title: String
  let systemImage: String
  let tint: Color
}

struct TaskBoardItemReviewReportSection: View {
  let item: TaskBoardItem
  let actions: TaskBoardOverviewActions
  let state: TaskBoardReviewReportState
  var initiallyShowsDetails = false
  var initiallyShowsFullSummary = false
  @Environment(\.fontScale)
  private var fontScale

  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      header
      reportContent
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.manage-item.review-report")
  }

  private var header: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingXS) {
      Label("AI Review", systemImage: "sparkles.rectangle.stack")
        .font(captionSemibold)
        .foregroundStyle(HarnessMonitorTheme.ink)
        .accessibilityAddTraits(.isHeader)
      Text("·")
        .font(captionFont)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .accessibilityHidden(true)
      Text(item.reviewIntentSubtitle)
        .font(captionFont)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(1)
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      if let headerStatus {
        TaskBoardReviewPill(
          title: headerStatus.title,
          systemImage: headerStatus.systemImage,
          tint: headerStatus.tint
        )
      }
    }
  }

  private var headerStatus: TaskBoardReviewHeaderStatus? {
    guard let response = state.response else { return nil }
    switch response {
    case .notStarted(let terminal):
      return terminal?.executionState.taskBoardReviewHeaderStatus
    case .running:
      return .init(title: "Running", systemImage: "bolt.fill", tint: HarnessMonitorTheme.accent)
    case .completed:
      return .init(
        title: "Completed",
        systemImage: "checkmark.circle.fill",
        tint: HarnessMonitorTheme.success
      )
    case .failed:
      return .init(
        title: "Failed",
        systemImage: "xmark.octagon.fill",
        tint: HarnessMonitorTheme.danger
      )
    case .cancelled:
      return .init(
        title: "Cancelled",
        systemImage: "slash.circle.fill",
        tint: HarnessMonitorTheme.caution
      )
    }
  }

  @ViewBuilder private var reportContent: some View {
    if let response = state.response {
      switch response {
      case .notStarted(let terminal):
        if let terminal {
          TaskBoardTerminalExecutionReport(
            item: item,
            executionState: terminal.executionState,
            terminalReason: item.workflow?.lastError,
            requestedRuntime: terminal.requestedRuntime,
            actualRuntime: terminal.actualRuntime,
            requestedModel: terminal.requestedModel,
            headRevision: terminal.headRevision,
            startedAt: terminal.startedAt,
            finishedAt: terminal.finishedAt
          )
        } else {
          TaskBoardReviewMessageCard(
            icon: "clock",
            title: "Waiting to start",
            detail: "No review execution has been recorded for this item",
            tint: HarnessMonitorTheme.secondaryInk
          )
        }
      case .running(
        let executionID,
        _,
        let requestedRuntime,
        let actualRuntime,
        let requestedModel,
        let headRevision,
        let startedAt
      ):
        TaskBoardReviewMetadataCard(
          provenance: TaskBoardReviewProvenance(
            executionID: executionID,
            repository: item.executionRepository,
            pullRequestNumber: item.workflow?.prNumber,
            requestedRuntime: requestedRuntime,
            actualRuntime: actualRuntime,
            model: requestedModel,
            headRevision: headRevision,
            startedAt: startedAt,
            finishedAt: nil
          )
        )
      case .completed(let report):
        terminalReport(
          report,
          status: .completed,
          tint: HarnessMonitorTheme.success
        )
      case .failed(let report):
        terminalReport(
          report,
          status: .failed,
          tint: HarnessMonitorTheme.danger
        )
      case .cancelled(let report):
        terminalReport(
          report,
          status: .cancelled,
          tint: HarnessMonitorTheme.caution
        )
      }
    } else if state.isLoading {
      HarnessMonitorLoadingStateView(title: "Loading review report")
    } else if state.didFail {
      TaskBoardReviewMessageCard(
        icon: "exclamationmark.triangle.fill",
        title: "Review report unavailable",
        detail: "The daemon could not load the latest report",
        tint: HarnessMonitorTheme.caution
      ) {
        Button("Retry") {
          reloadReviewReport()
        }
        .font(captionSemibold)
        .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      }
    }
  }

  private func terminalReport(
    _ report: TaskBoardAiReviewReportRecord,
    status: TaskBoardAiReviewReportStatus,
    tint: Color
  ) -> some View {
    let presentation = TaskBoardReviewTerminalPresentation(report: report, status: status)
    return VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      if report.isStale(comparedWith: item.workflow?.prHeadRevision) {
        TaskBoardReviewStaleHeadCard(
          repository: report.repository,
          reportHead: report.headRevision,
          currentHead: item.workflow?.prHeadRevision
        )
      }
      TaskBoardReviewMetadataCard(
        provenance: TaskBoardReviewProvenance(
          executionID: nil,
          repository: report.repository,
          pullRequestNumber: report.pullRequestNumber,
          requestedRuntime: report.requestedRuntime,
          actualRuntime: report.actualRuntime,
          model: report.effectiveModel ?? report.requestedModel,
          headRevision: report.headRevision,
          startedAt: report.startedAt,
          finishedAt: report.finishedAt
        ),
        initiallyShowsDetails: initiallyShowsDetails
      )
      if let summary = report.summary, !summary.isEmpty {
        TaskBoardReviewTextSection(
          title: "Summary",
          systemImage: "text.alignleft",
          content: summary,
          collapsedLineLimit: 4,
          initiallyExpanded: initiallyShowsFullSummary
        )
      }
      if let reason = presentation.terminalDetail {
        TaskBoardReviewMessageCard(
          icon: "exclamationmark.bubble.fill",
          title: "Terminal reason",
          detail: reason,
          tint: tint
        )
      }
      if let partialOutput = presentation.visiblePartialOutput {
        TaskBoardReviewTextSection(
          title: "Partial output",
          systemImage: "doc.text",
          content: partialOutput
        )
      }
      if presentation.showsGeneratedSections {
        TaskBoardReviewFindingsSection(
          findings: report.findings,
          repository: report.repository,
          revision: report.headRevision,
          status: status
        )
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  private func reloadReviewReport() {
    let store = actions.store
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Reloading task board review report") {
        await state.load(item: item, store: store)
      }
    )
  }
}

private struct TaskBoardTerminalExecutionReport: View {
  let item: TaskBoardItem
  let executionState: TaskBoardExecutionState
  let terminalReason: String?
  let requestedRuntime: String
  let actualRuntime: String?
  let requestedModel: String?
  let headRevision: String?
  let startedAt: String
  let finishedAt: String

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      TaskBoardReviewMessageCard(
        icon: executionState.taskBoardReviewSystemImage,
        title: "Report unavailable",
        detail: reportUnavailableDetail,
        tint: executionState.taskBoardReviewTint
      )
      TaskBoardReviewMetadataCard(
        provenance: TaskBoardReviewProvenance(
          executionID: nil,
          repository: item.executionRepository,
          pullRequestNumber: item.workflow?.prNumber,
          requestedRuntime: requestedRuntime,
          actualRuntime: actualRuntime,
          model: requestedModel,
          headRevision: headRevision,
          startedAt: startedAt,
          finishedAt: finishedAt
        )
      )
    }
  }

  private var reportUnavailableDetail: String {
    if let terminalReason,
      !terminalReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return terminalReason
    }
    switch executionState {
    case .completed:
      return "The review finished before Harness retained a report"
    case .cancelled:
      return "The review was cancelled before Harness retained a report"
    default:
      return "The review stopped before Harness retained a report"
    }
  }
}

extension TaskBoardExecutionState {
  fileprivate var taskBoardReviewHeaderStatus: TaskBoardReviewHeaderStatus {
    .init(
      title: taskBoardReviewTitle,
      systemImage: taskBoardReviewSystemImage,
      tint: taskBoardReviewTint
    )
  }

  fileprivate var taskBoardReviewTitle: String {
    switch self {
    case .completed: "Completed"
    case .failed: "Failed"
    case .cancelled: "Cancelled"
    default: "Finished"
    }
  }

  fileprivate var taskBoardReviewSystemImage: String {
    switch self {
    case .completed: "checkmark.circle.fill"
    case .failed: "xmark.octagon.fill"
    case .cancelled: "slash.circle.fill"
    default: "checkmark.seal.fill"
    }
  }

  fileprivate var taskBoardReviewTint: Color {
    switch self {
    case .completed: HarnessMonitorTheme.success
    case .failed: HarnessMonitorTheme.danger
    case .cancelled: HarnessMonitorTheme.caution
    default: HarnessMonitorTheme.secondaryInk
    }
  }
}

extension TaskBoardItem {
  var showsReviewReport: Bool {
    matchesReviewWorkflow
  }

  fileprivate var reviewIntentSubtitle: String {
    switch workflowKind {
    case .some(.prReview):
      "Pull request"
    case .some(.review):
      "Completed work"
    default:
      "General"
    }
  }

  private var matchesReviewWorkflow: Bool {
    switch workflowKind {
    case .some(.prReview), .some(.review):
      true
    default:
      false
    }
  }
}

extension TaskBoardAiReviewReportRecord {
  func isStale(comparedWith currentHeadRevision: String?) -> Bool {
    guard let currentHeadRevision else { return false }
    return headRevision != currentHeadRevision
  }
}
