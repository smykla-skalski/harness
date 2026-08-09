import AppKit
import HarnessMonitorKit
import SwiftUI

#Preview("Step Mode - no ready item") {
  TaskBoardStepRailPreviewFixtures.panel(item: nil, record: nil)
}

#Preview("Step Mode - ready to pick") {
  TaskBoardStepRailPreviewFixtures.panel(
    item: TaskBoardStepRailPreviewFixtures.item(status: .todo),
    record: nil
  )
}

#Preview("Step Mode - worker running") {
  TaskBoardStepRailPreviewFixtures.panel(
    item: TaskBoardStepRailPreviewFixtures.item(status: .inProgress, currentStepId: "worker"),
    record: nil
  )
}

#Preview("Step Mode - awaiting review") {
  TaskBoardStepRailPreviewFixtures.panel(
    item: TaskBoardStepRailPreviewFixtures.item(status: .toReview),
    record: TaskBoardStepRailPreviewFixtures.record(
      taskStatus: .awaitingReview,
      outcome: .reviewPending
    )
  )
}

#Preview("Step Mode - changes requested") {
  TaskBoardStepRailPreviewFixtures.panel(
    item: TaskBoardStepRailPreviewFixtures.item(
      status: .inReview,
      prUrl: "https://example.com/pr/7"
    ),
    record: TaskBoardStepRailPreviewFixtures.record(
      taskStatus: .inReview,
      outcome: .reviewChangesRequested,
      reason: "Tighten the retry backoff"
    )
  )
}

#Preview("Step Mode - done") {
  TaskBoardStepRailPreviewFixtures.panel(
    item: TaskBoardStepRailPreviewFixtures.item(status: .done),
    record: nil
  )
}

#Preview("Step Mode - held ownership") {
  TaskBoardHeldDispatchesPreviewSurface()
    .harnessPreviewSceneAppearance()
}

private struct TaskBoardHeldDispatchesPreviewSurface: View {
  var body: some View {
    TaskBoardHeldDispatchesView(
      summary: TaskBoardHeldDispatchesPreviewFixture.summary,
      initiallyExpanded: true
    )
    .padding(24)
    .frame(width: 720, alignment: .leading)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

private enum TaskBoardHeldDispatchesPreviewFixture {
  static let summary = TaskBoardHeldDispatchSummary(
    count: 3,
    items: [
      TaskBoardHeldDispatchItem(
        intentId: "intent-workspace",
        boardItemId: "harness-workspace-owned",
        workspaceId: "workspace-harness-main",
        workingCopyId: "copy-implementation-17",
        workItemId: "implementation:17"
      ),
      TaskBoardHeldDispatchItem(
        intentId: "intent-session",
        boardItemId: "harness-legacy-session",
        sessionId: "session-review-42",
        workItemId: "review:42"
      ),
      TaskBoardHeldDispatchItem(
        intentId: "intent-working-copy",
        boardItemId: "harness-working-copy-only",
        workingCopyId: "copy-recovery-23",
        workItemId: "implementation:23"
      ),
    ]
  )
}

@MainActor
public enum TaskBoardStepRailPreviewRenderer {
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
      name: "held-ownership-default",
      textSizeIndex: HarnessMonitorTextSize.defaultIndex,
      directory: directory
    )
      && render(
        name: "held-ownership-largest-text",
        textSizeIndex: HarnessMonitorTextSize.scales.count - 1,
        directory: directory
      )
      && TaskBoardDispatchAppliedRowsPreviewRenderer.dump(toDirectory: directory)
  }

  private static func render(
    name: String,
    textSizeIndex: Int,
    directory: String
  ) -> Bool {
    let view = NSHostingView(
      rootView: TaskBoardHeldDispatchesPreviewSurface()
        .harnessPreviewSceneAppearance(textSizeIndex: textSizeIndex)
    )
    view.setFrameSize(NSSize(width: 720, height: 1))
    view.layoutSubtreeIfNeeded()
    view.setFrameSize(NSSize(width: 720, height: view.fittingSize.height))
    let window = NSWindow(
      contentRect: view.bounds,
      styleMask: .borderless,
      backing: .buffered,
      defer: false,
      screen: NSScreen.main
    )
    window.contentView = view
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

@MainActor
private enum TaskBoardStepRailPreviewFixtures {
  static let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .taskBoardBoardOnly)

  static let status = TaskBoardOrchestratorStatus(
    enabled: true,
    running: false,
    stepMode: true,
    settings: TaskBoardOrchestratorSettings(
      enabledWorkflows: [.defaultTask, .prReview],
      dryRunDefault: false,
      policyVersion: "preview"
    )
  )

  static func item(
    status: TaskBoardStatus,
    currentStepId: String? = nil,
    prUrl: String? = nil
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: "board-preview",
      title: "Wire cached refresh entry point",
      body: "Load cached session details into the inbox snapshot.",
      status: status,
      priority: .medium,
      tags: [],
      projectId: "project-task-board",
      targetProjectTypes: [],
      agentMode: .interactive,
      externalRefs: [],
      planning: TaskBoardPlanningState(),
      workflow: TaskBoardWorkflowState(
        status: .running,
        currentStepId: currentStepId,
        prUrl: prUrl
      ),
      sessionId: "sess-task-board",
      workItemId: "task-board-refresh",
      usage: TaskBoardUsage(),
      createdAt: "2026-05-14T10:00:00Z",
      updatedAt: "2026-05-14T10:01:00Z",
      deletedAt: nil
    )
  }

  static func record(
    taskStatus: TaskStatus,
    outcome: TaskBoardEvaluationOutcome,
    reason: String? = nil
  ) -> TaskBoardEvaluationRecord {
    TaskBoardEvaluationRecord(
      boardItemId: "board-preview",
      outcome: outcome,
      taskStatus: taskStatus,
      reason: reason
    )
  }

  static func panel(item: TaskBoardItem?, record: TaskBoardEvaluationRecord?) -> some View {
    TaskBoardStepRailView(
      store: store,
      status: status,
      latestEvaluation: record.map { TaskBoardEvaluationSummary(records: [$0]) },
      workspace: nil,
      targetItem: item,
      taskBoardItems: item.map { [$0] } ?? [],
      isActionInFlight: false,
      actions: TaskBoardOverviewActions(store: store, scope: .dashboard),
      flowDefaults: .standard
    )
    .padding(24)
    .frame(width: 900)
  }
}
