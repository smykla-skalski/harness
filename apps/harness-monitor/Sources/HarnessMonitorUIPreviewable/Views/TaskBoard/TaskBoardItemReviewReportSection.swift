import HarnessMonitorKit
import SwiftUI

struct TaskBoardItemReviewReportSection: View {
  let item: TaskBoardItem
  let actions: TaskBoardOverviewActions
  let state: TaskBoardReviewReportState
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
    VStack(alignment: .leading, spacing: 2) {
      Label("AI Review", systemImage: "sparkles.rectangle.stack")
        .font(captionSemibold)
        .foregroundStyle(HarnessMonitorTheme.ink)
        .accessibilityAddTraits(.isHeader)
      Text("\(item.reviewIntentTitle) · Workflow \(item.workflow?.status.title ?? "Idle")")
        .font(captionFont)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
  }

  @ViewBuilder private var reportContent: some View {
    if let response = state.response {
      switch response {
      case .notStarted:
        TaskBoardReviewMessageCard(
          icon: "clock",
          title: "Waiting to start",
          detail: "No review execution has been recorded for this item.",
          tint: HarnessMonitorTheme.secondaryInk
        )
      case .running(
        let executionID,
        let runtime,
        let requestedModel,
        let headRevision,
        let startedAt
      ):
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          HStack(spacing: HarnessMonitorTheme.spacingSM) {
            ProgressView()
              .controlSize(.small)
            TaskBoardReviewStatusPill(
              title: "Running",
              systemImage: "bolt.fill",
              tint: HarnessMonitorTheme.accent
            )
          }
          TaskBoardReviewMetadataCard(
            provenance: TaskBoardReviewProvenance(
              executionID: executionID,
              repository: item.executionRepository,
              pullRequestNumber: item.workflow?.prNumber,
              runtime: runtime,
              model: requestedModel,
              headRevision: headRevision,
              startedAt: startedAt,
              finishedAt: nil
            )
          )
        }
      case .completed(let report):
        terminalReport(
          report,
          title: "Completed",
          systemImage: "checkmark.circle.fill",
          tint: HarnessMonitorTheme.success
        )
      case .failed(let report):
        terminalReport(
          report,
          title: "Failed",
          systemImage: "xmark.octagon.fill",
          tint: HarnessMonitorTheme.danger
        )
      case .cancelled(let report):
        terminalReport(
          report,
          title: "Cancelled",
          systemImage: "slash.circle.fill",
          tint: HarnessMonitorTheme.caution
        )
      }
    } else if state.isLoading {
      HarnessMonitorLoadingStateView(title: "Loading review report")
    } else if state.didFail {
      TaskBoardReviewMessageCard(
        icon: "exclamationmark.triangle.fill",
        title: "Review report unavailable",
        detail: "The daemon could not load the latest report.",
        tint: HarnessMonitorTheme.caution
      ) {
        Button("Retry") {
          Task { await state.load(item: item, actions: actions) }
        }
        .font(captionSemibold)
        .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      }
    }
  }

  private func terminalReport(
    _ report: TaskBoardAiReviewReportRecord,
    title: String,
    systemImage: String,
    tint: Color
  ) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      TaskBoardReviewStatusPill(title: title, systemImage: systemImage, tint: tint)
      if report.isStale(comparedWith: item.workflow?.prHeadRevision) {
        TaskBoardReviewStaleHeadCard(
          reportHead: report.headRevision,
          currentHead: item.workflow?.prHeadRevision
        )
      }
      TaskBoardReviewMetadataCard(
        provenance: TaskBoardReviewProvenance(
          executionID: nil,
          repository: report.repository,
          pullRequestNumber: report.pullRequestNumber,
          runtime: report.runtime,
          model: report.effectiveModel ?? report.requestedModel,
          headRevision: report.headRevision,
          startedAt: report.startedAt,
          finishedAt: report.finishedAt
        )
      )
      if let summary = report.summary, !summary.isEmpty {
        TaskBoardReviewTextCard(
          title: "Summary",
          systemImage: "text.alignleft",
          content: summary
        )
      }
      if let reason = report.terminalReason, !reason.isEmpty {
        TaskBoardReviewMessageCard(
          icon: "exclamationmark.bubble.fill",
          title: "Terminal reason",
          detail: reason,
          tint: tint
        )
      }
      if let partialOutput = report.partialOutput, !partialOutput.isEmpty {
        TaskBoardReviewTextCard(
          title: "Partial output",
          systemImage: "doc.text",
          content: partialOutput
        )
      }
      TaskBoardReviewFindingsSection(findings: report.findings)
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}

extension TaskBoardItem {
  var showsReviewReport: Bool {
    matchesReviewWorkflow
  }

  fileprivate var reviewIntentTitle: String {
    switch workflowKind {
    case .some(.prReview):
      "Pull request review"
    case .some(.review):
      "Completed work review"
    default:
      "AI review"
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
