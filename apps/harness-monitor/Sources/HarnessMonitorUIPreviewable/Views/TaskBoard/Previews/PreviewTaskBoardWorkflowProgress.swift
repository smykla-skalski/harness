import AppKit
import HarnessMonitorKit
import SwiftUI

#Preview("Task Board Workflow Progress") {
  TaskBoardWorkflowProgressPreviewSurface()
    .harnessPreviewSceneAppearance()
}

#Preview("Task Board Workflow Progress — Step Details") {
  TaskBoardWorkflowStepDetailSheet(
    step: TaskBoardWorkflowProgressPreviewFixture.triage.nextSteps[0]
  )
  .harnessPreviewSceneAppearance()
}

#Preview("Task Board Workflow Progress — Largest Text") {
  TaskBoardWorkflowProgressPreviewSurface()
    .harnessPreviewSceneAppearance(
      textSizeIndex: HarnessMonitorTextSize.scales.count - 1
    )
}

#Preview("Task Board Workflow Progress — Attempt Details") {
  TaskBoardWorkflowAttemptDetailSheet(
    attempt: TaskBoardWorkflowProgressPreviewFixture.attempts[0]
  )
  .harnessPreviewSceneAppearance()
}

@MainActor
private struct TaskBoardWorkflowProgressPreviewSurface: View {
  @State private var state = TaskBoardWorkflowProgressState(
    response: TaskBoardWorkflowProgressPreviewFixture.response
  )

  var body: some View {
    TaskBoardItemWorkflowProgressSection(
      item: TaskBoardWorkflowProgressPreviewFixture.item,
      actions: TaskBoardOverviewActions(store: nil, scope: .dashboard),
      state: state
    )
    .padding(24)
    .frame(width: 600, alignment: .topLeading)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

private enum TaskBoardWorkflowProgressPreviewFixture {
  static let head = "dc78a2698cb7b5e197825a81bd92bb12c8109b81"

  static let item = TaskBoardItem(
    schemaVersion: 1,
    id: "workflow-progress-preview",
    title: "Update serde to 1.0.221",
    body: "Apply the dependency update and repair its failed checks",
    status: .inProgress,
    priority: .high,
    tags: ["dependencies", "rust"],
    projectId: "harness",
    executionRepository: "smykla-skalski/harness",
    agentMode: .interactive,
    workflowKind: .prFixReview,
    externalRefs: [],
    planning: TaskBoardPlanningState(),
    workflow: TaskBoardWorkflowState(
      executionId: "workflow-progress-execution",
      status: .running,
      currentStepId: "dependency_fix",
      attempts: 2,
      prNumber: 920,
      prUrl: "https://github.com/smykla-skalski/harness/pull/920",
      prHeadRevision: head
    ),
    sessionId: nil,
    workItemId: nil,
    usage: TaskBoardUsage(),
    createdAt: "2026-07-30T08:00:00Z",
    updatedAt: "2026-07-30T08:11:22Z",
    deletedAt: nil
  )

  static let triage = TaskBoardDependencyTriageResult(
    schemaVersion: 1,
    repository: "smykla-skalski/harness",
    pullRequestNumber: 920,
    exactHeadRevision: head,
    dependency: TaskBoardDependencyIdentity(
      name: "serde",
      ecosystem: "cargo",
      currentVersion: "1.0.219",
      targetVersion: "1.0.221",
      updateClass: .patch
    ),
    checks: [
      TaskBoardDependencyCheck(
        name: "Rust",
        state: .failed,
        detailsUrl: "https://github.com/smykla-skalski/harness/actions/runs/920"
      ),
      TaskBoardDependencyCheck(
        name: "Monitor",
        state: .pending,
        detailsUrl: "https://github.com/smykla-skalski/harness/actions/runs/921"
      ),
    ],
    conflicts: TaskBoardDependencyConflictEvidence(
      state: .clean,
      summary: "The pull request applies cleanly to its exact head"
    ),
    approvals: TaskBoardDependencyApprovalEvidence(current: 1, required: 1),
    safetyAssumption: "The repair stays within dependency-owned generated files",
    disposition: .fixRequired,
    requiredTools: ["github.read", "codex.dispatch"],
    nextSteps: [
      TaskBoardDependencyTriageStep(
        order: 1,
        action: "inspect_failed_checks",
        reason: "Use exact-head diagnostics before changing the patch"
      ),
      TaskBoardDependencyTriageStep(
        order: 2,
        action: "dispatch_fixer",
        reason: "Apply the smallest proven repair and rerun failed checks"
      ),
    ]
  )

  static let attempts = [
    TaskBoardWorkflowAttemptProgress(
      actionKey: "dependency_triage",
      attempt: 1,
      state: .completed,
      runtime: "openrouter",
      model: "deepseek/deepseek-v4-flash",
      report: "Classified the update as a safe patch with one failing required check",
      startedAt: "2026-07-30T08:10:00Z",
      updatedAt: "2026-07-30T08:10:14Z",
      completedAt: "2026-07-30T08:10:14Z"
    ),
    TaskBoardWorkflowAttemptProgress(
      actionKey: "dependency_fix",
      attempt: 1,
      state: .running,
      runtime: "codex",
      model: "gpt-5.3-codex-spark",
      report: "Inspecting the failed Rust check against the selected revision",
      startedAt: "2026-07-30T08:11:00Z",
      updatedAt: "2026-07-30T08:11:22Z"
    ),
  ]

  static let response = TaskBoardWorkflowProgressResponse(
    progress: TaskBoardWorkflowProgress(
      executionId: "workflow-progress-execution",
      workflowKind: .prFixReview,
      phase: .implementation,
      state: .running,
      exactHeadRevision: head,
      currentRuntime: "codex",
      currentModel: "gpt-5.3-codex-spark",
      triage: TaskBoardDependencyRouteRecord(
        routeId: "dependency-preview-route",
        repository: triage.repository,
        pullRequestNumber: triage.pullRequestNumber,
        exactHeadRevision: head,
        status: .fixRequested,
        reason: "The failed Rust check requires a scoped repair",
        sourceResult: triage
      ),
      attempts: attempts,
      createdAt: "2026-07-30T08:10:00Z",
      updatedAt: "2026-07-30T08:11:22Z"
    )
  )
}

@MainActor
public enum TaskBoardWorkflowProgressPreviewRenderer {
  public static func dump(toDirectory directory: String) -> Bool {
    do {
      try FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: true
      )
    } catch {
      return false
    }

    return render(
      name: "workflow-progress-default",
      textSizeIndex: HarnessMonitorTextSize.defaultIndex,
      content: TaskBoardWorkflowProgressPreviewSurface(),
      directory: directory
    )
      && render(
        name: "workflow-progress-next-step-details",
        textSizeIndex: HarnessMonitorTextSize.defaultIndex,
        content: TaskBoardWorkflowStepDetailSheet(
          step: TaskBoardWorkflowProgressPreviewFixture.triage.nextSteps[0]
        ),
        directory: directory
      )
      && render(
        name: "workflow-progress-largest-text",
        textSizeIndex: HarnessMonitorTextSize.scales.count - 1,
        content: TaskBoardWorkflowProgressPreviewSurface(),
        directory: directory
      )
      && render(
        name: "workflow-progress-attempt-details",
        textSizeIndex: HarnessMonitorTextSize.defaultIndex,
        content: TaskBoardWorkflowAttemptDetailSheet(
          attempt: TaskBoardWorkflowProgressPreviewFixture.attempts[0]
        ),
        directory: directory
      )
  }

  private static func render<Content: View>(
    name: String,
    textSizeIndex: Int,
    content: Content,
    directory: String
  ) -> Bool {
    let view = NSHostingView(
      rootView: content.harnessPreviewSceneAppearance(textSizeIndex: textSizeIndex)
    )
    view.setFrameSize(NSSize(width: 600, height: 1))
    view.layoutSubtreeIfNeeded()
    let fittingSize = view.fittingSize
    view.setFrameSize(NSSize(width: 600, height: fittingSize.height))
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
    view.setFrameSize(NSSize(width: 600, height: settledSize.height))
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
