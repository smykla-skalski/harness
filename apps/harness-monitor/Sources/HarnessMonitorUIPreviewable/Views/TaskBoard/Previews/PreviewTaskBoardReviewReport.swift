import AppKit
import HarnessMonitorKit
import SwiftUI

#Preview("Task Board Review Report") {
  TaskBoardReviewReportPreviewSurface()
    .harnessPreviewSceneAppearance()
}

#Preview("Task Board Review Report — Largest Text") {
  TaskBoardReviewReportPreviewSurface()
    .harnessPreviewSceneAppearance(
      textSizeIndex: HarnessMonitorTextSize.scales.count - 1
    )
}

@MainActor
private struct TaskBoardReviewReportPreviewSurface: View {
  @State private var state = TaskBoardReviewReportState(
    response: .completed(report: TaskBoardReviewReportPreviewFixture.report)
  )

  var body: some View {
    TaskBoardItemReviewReportSection(
      item: TaskBoardReviewReportPreviewFixture.item,
      actions: TaskBoardOverviewActions(store: nil, scope: .dashboard),
      state: state
    )
    .padding(24)
    .frame(width: 560, alignment: .topLeading)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

private enum TaskBoardReviewReportPreviewFixture {
  static let currentHead = String(repeating: "b", count: 40)
  static let reportHead = String(repeating: "a", count: 40)

  static let item = TaskBoardItem(
    schemaVersion: 1,
    id: "review-report-preview",
    title: "Review pull request #901",
    body: "Inspect the selected immutable revision.",
    status: .inReview,
    priority: .high,
    tags: ["review"],
    projectId: "harness",
    executionRepository: "smykla-skalski/harness",
    agentMode: .evaluate,
    workflowKind: .prReview,
    externalRefs: [],
    planning: TaskBoardPlanningState(),
    workflow: TaskBoardWorkflowState(
      status: .completed,
      prNumber: 901,
      prUrl: "https://github.com/smykla-skalski/harness/pull/901",
      prHeadRevision: currentHead
    ),
    sessionId: nil,
    workItemId: nil,
    usage: TaskBoardUsage(),
    createdAt: "2026-07-29T19:35:00Z",
    updatedAt: "2026-07-29T19:42:00Z",
    deletedAt: nil
  )

  static let report = TaskBoardAiReviewReportRecord(
    reportId: "report-preview-901",
    itemId: item.id,
    correlationId: "correlation-preview-901",
    repository: "smykla-skalski/harness",
    pullRequestNumber: 901,
    headRevision: reportHead,
    runtime: "openrouter",
    requestedModel: "deepseek/deepseek-v4-flash",
    effectiveModel: "deepseek/deepseek-v4-flash",
    status: .completed,
    summary: "The review completed with one actionable finding.",
    findings: [
      TaskBoardReportOnlyReviewFinding(
        severity: .medium,
        location: TaskBoardReviewFindingLocation(path: "src/review.rs", line: 42),
        evidence: "The retry path does not preserve the original correlation id."
      )
    ],
    startedAt: "2026-07-29T19:40:00Z",
    finishedAt: "2026-07-29T19:41:12Z"
  )
}

extension TaskBoardInspectorPreviewRenderer {
  static func dumpReviewReport(toDirectory directory: String) -> Bool {
    renderReviewReport(
      name: "review-report-default",
      textSizeIndex: HarnessMonitorTextSize.defaultIndex,
      directory: directory
    )
      && renderReviewReport(
        name: "review-report-largest-text",
        textSizeIndex: HarnessMonitorTextSize.scales.count - 1,
        directory: directory
      )
  }

  private static func renderReviewReport(
    name: String,
    textSizeIndex: Int,
    directory: String
  ) -> Bool {
    let content =
      TaskBoardReviewReportPreviewSurface()
      .harnessPreviewSceneAppearance(textSizeIndex: textSizeIndex)
    let view = NSHostingView(rootView: content)
    let height: CGFloat =
      textSizeIndex == HarnessMonitorTextSize.scales.count - 1 ? 760 : 560
    view.setFrameSize(NSSize(width: 560, height: height))
    view.layoutSubtreeIfNeeded()

    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      return false
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else {
      return false
    }
    do {
      try data.write(
        to: URL(fileURLWithPath: directory)
          .appendingPathComponent(name)
          .appendingPathExtension("png"),
        options: .atomic
      )
      return true
    } catch {
      return false
    }
  }
}
