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

#Preview("Task Board Review Terminal Execution") {
  TaskBoardReviewReportPreviewSurface(
    item: TaskBoardReviewReportPreviewFixture.terminalItem,
    response: TaskBoardReviewReportPreviewFixture.terminalResponse
  )
  .harnessPreviewSceneAppearance()
}

#Preview("Task Board Review Report — Failed") {
  TaskBoardReviewReportPreviewSurface(
    response: .failed(report: TaskBoardReviewReportPreviewFixture.failedReport)
  )
  .harnessPreviewSceneAppearance()
}

#Preview("Task Board Review Report — Cancelled") {
  TaskBoardReviewReportPreviewSurface(
    response: .cancelled(report: TaskBoardReviewReportPreviewFixture.cancelledReport)
  )
  .harnessPreviewSceneAppearance()
}

@MainActor
private struct TaskBoardReviewReportPreviewSurface: View {
  @State private var state: TaskBoardReviewReportState
  private let item: TaskBoardItem
  private let initiallyExpanded: Bool

  init(
    item: TaskBoardItem = TaskBoardReviewReportPreviewFixture.item,
    response: TaskBoardAiReviewReportResponse = .completed(
      report: TaskBoardReviewReportPreviewFixture.report
    ),
    initiallyExpanded: Bool = false
  ) {
    self.item = item
    self.initiallyExpanded = initiallyExpanded
    _state = State(initialValue: TaskBoardReviewReportState(response: response))
  }

  var body: some View {
    TaskBoardItemReviewReportSection(
      item: item,
      actions: TaskBoardOverviewActions(store: nil, scope: .dashboard),
      state: state,
      initiallyShowsDetails: initiallyExpanded,
      initiallyShowsFullSummary: initiallyExpanded
    )
    .padding(24)
    .frame(width: 560, alignment: .topLeading)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

private enum TaskBoardReviewReportPreviewFixture {
  static let currentHead = "dc78a2698cb7b5e197825a81bd92bb12c8109b81"
  static let reportHead = "b08dca3c08f699e66ee97162f425539667936848"

  static let item = makeItem(workflowStatus: .completed)
  static let terminalItem = makeItem(workflowStatus: .failed)

  static let report = TaskBoardAiReviewReportRecord(
    reportId: "report-preview-901",
    itemId: item.id,
    correlationId: "correlation-preview-901",
    repository: "smykla-skalski/harness",
    pullRequestNumber: 901,
    headRevision: reportHead,
    runtime: "openrouter",
    requestedRuntime: "openrouter",
    actualRuntime: "openrouter",
    requestedModel: "deepseek/deepseek-v4-flash",
    effectiveModel: "deepseek/deepseek-v4-flash",
    status: .completed,
    summary: """
      The review validates the new multi-runtime execution path across local and remote task-board \
      workflows. Runtime selection is now frozen from the reviewer profile before an offer is \
      created, and the remote executor routes OpenRouter work through the durable agent turn store \
      while leaving the existing Codex path intact. Requested and actual runtime provenance is \
      retained with the originating ticket so operators can distinguish configuration intent from \
      the adapter that performed the work

      Four findings remain. The two blocking findings concern stale executor fencing and restart \
      reconciliation, where concurrent ownership changes could publish an obsolete result or start \
      the same OpenRouter turn twice. The medium finding identifies a report path that reads current \
      configuration instead of durable execution provenance. The low finding asks for explicit \
      regression coverage proving that remote Codex runs continue to use codex_runs and never enter \
      agent_turn_runs. Address the blocking findings before merging and retain the lower-severity \
      cases as acceptance coverage for the final delivery
      """,
    findings: [
      TaskBoardReportOnlyReviewFinding(
        severity: .critical,
        location: TaskBoardReviewFindingLocation(
          path: "src/service/serve/task_board_remote_executor_loop/openrouter.rs",
          line: 184
        ),
        evidence: """
          A resumed OpenRouter run can publish after its lease is fenced, allowing a stale \
          executor to overwrite the authoritative result
          """
      ),
      TaskBoardReportOnlyReviewFinding(
        severity: .high,
        location: TaskBoardReviewFindingLocation(
          path: "src/service/serve/task_board_remote_executor_loop/reconcile.rs",
          line: 92
        ),
        evidence: """
          Restart reconciliation can start a second agent turn before the interrupted durable \
          run is adopted
          """
      ),
      TaskBoardReportOnlyReviewFinding(
        severity: .medium,
        location: TaskBoardReviewFindingLocation(
          path: "src/service/serve/task_board_review_report.rs",
          line: 147
        ),
        evidence: """
          The ticket report reads the configured runtime instead of the actual runtime retained \
          by the durable run
          """
      ),
      TaskBoardReportOnlyReviewFinding(
        severity: .low,
        location: TaskBoardReviewFindingLocation(
          path: "tests/integration/daemon_control/restart_boundaries/task_board_admission.rs",
          line: 311
        ),
        evidence: """
          The restart fixture does not assert that Codex runs remain isolated from \
          agent_turn_runs
          """
      ),
    ],
    startedAt: "2026-07-29T19:40:00Z",
    finishedAt: "2026-07-29T19:41:12Z"
  )

  static let terminalResponse = TaskBoardAiReviewReportResponse.notStarted(
    terminal: TaskBoardAiReviewUnavailableExecution(
      executionId: "execution-preview-901",
      executionState: .failed,
      runtime: "openrouter",
      requestedRuntime: "openrouter",
      actualRuntime: "openrouter",
      requestedModel: "deepseek/deepseek-v4-flash",
      headRevision: currentHead,
      startedAt: "2026-07-29T19:40:00Z",
      finishedAt: "2026-07-29T19:41:12Z"
    )
  )

  private static func makeItem(workflowStatus: TaskBoardWorkflowStatus) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: "review-report-preview",
      title: "Review pull request #901",
      body: "Inspect the selected immutable revision",
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
        status: workflowStatus,
        prNumber: 901,
        prUrl: "https://github.com/smykla-skalski/harness/pull/901",
        prHeadRevision: currentHead,
        lastError: workflowStatus == .failed
          ? "The OpenRouter review stopped before producing a report"
          : nil
      ),
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      createdAt: "2026-07-29T19:35:00Z",
      updatedAt: "2026-07-29T19:42:00Z",
      deletedAt: nil
    )
  }

  static var failedReport: TaskBoardAiReviewReportRecord {
    var report = report
    report.status = .failed
    report.summary = nil
    report.findings = []
    report.partialOutput = "The provider returned an incomplete structured response."
    report.terminalReason = "The response did not satisfy the report-only result contract."
    return report
  }

  static var cancelledReport: TaskBoardAiReviewReportRecord {
    var report = report
    report.status = .cancelled
    report.summary = nil
    report.findings = []
    report.partialOutput = nil
    report.terminalReason = "Cancelled by the operator before findings were produced."
    return report
  }
}

@MainActor
public enum TaskBoardReviewReportPreviewRenderer {
  public static func dump(toDirectory directory: String) -> Bool {
    do {
      try FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: true
      )
    } catch {
      return false
    }

    return renderReviewReport(
      name: "review-report-default",
      textSizeIndex: HarnessMonitorTextSize.defaultIndex,
      directory: directory
    )
      && renderReviewReport(
        name: "review-report-expanded-default",
        textSizeIndex: HarnessMonitorTextSize.defaultIndex,
        initiallyExpanded: true,
        directory: directory
      )
      && renderReviewReport(
        name: "review-report-largest-text",
        textSizeIndex: HarnessMonitorTextSize.scales.count - 1,
        directory: directory
      )
      && renderReviewReport(
        name: "review-report-expanded-largest-text",
        textSizeIndex: HarnessMonitorTextSize.scales.count - 1,
        initiallyExpanded: true,
        directory: directory
      )
      && renderReviewReport(
        name: "review-report-terminal-default",
        textSizeIndex: HarnessMonitorTextSize.defaultIndex,
        item: TaskBoardReviewReportPreviewFixture.terminalItem,
        response: TaskBoardReviewReportPreviewFixture.terminalResponse,
        directory: directory
      )
      && renderReviewReport(
        name: "review-report-failed",
        textSizeIndex: HarnessMonitorTextSize.defaultIndex,
        response: .failed(report: TaskBoardReviewReportPreviewFixture.failedReport),
        directory: directory
      )
      && renderReviewReport(
        name: "review-report-cancelled",
        textSizeIndex: HarnessMonitorTextSize.defaultIndex,
        response: .cancelled(report: TaskBoardReviewReportPreviewFixture.cancelledReport),
        directory: directory
      )
      && renderReviewReport(
        name: "review-report-terminal-largest-text",
        textSizeIndex: HarnessMonitorTextSize.scales.count - 1,
        item: TaskBoardReviewReportPreviewFixture.terminalItem,
        response: TaskBoardReviewReportPreviewFixture.terminalResponse,
        directory: directory
      )
  }

  private static func renderReviewReport(
    name: String,
    textSizeIndex: Int,
    item: TaskBoardItem = TaskBoardReviewReportPreviewFixture.item,
    response: TaskBoardAiReviewReportResponse = .completed(
      report: TaskBoardReviewReportPreviewFixture.report
    ),
    initiallyExpanded: Bool = false,
    directory: String
  ) -> Bool {
    let content =
      TaskBoardReviewReportPreviewSurface(
        item: item,
        response: response,
        initiallyExpanded: initiallyExpanded
      )
      .harnessPreviewSceneAppearance(textSizeIndex: textSizeIndex)
    let view = NSHostingView(rootView: content)
    view.setFrameSize(NSSize(width: 560, height: 1))
    view.layoutSubtreeIfNeeded()
    let fittingSize = view.fittingSize
    view.setFrameSize(
      NSSize(
        width: 560,
        height: fittingSize.height
      )
    )
    let window = NSWindow(
      contentRect: view.bounds,
      styleMask: .borderless,
      backing: .buffered,
      defer: false,
      screen: NSScreen.main
    )
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    let settledSize = view.fittingSize
    view.setFrameSize(
      NSSize(
        width: 560,
        height: settledSize.height
      )
    )
    window.setContentSize(view.frame.size)
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
