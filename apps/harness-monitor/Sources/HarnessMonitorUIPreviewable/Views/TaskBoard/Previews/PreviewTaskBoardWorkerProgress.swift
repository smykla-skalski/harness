import AppKit
import HarnessMonitorKit
import SwiftUI

#Preview("Task Board Worker Progress") {
  TaskBoardWorkerProgressPreviewSurface(response: TaskBoardWorkerProgressPreviewFixture.running)
    .harnessPreviewSceneAppearance()
}

#Preview("Task Board Worker Progress — Early") {
  TaskBoardWorkerProgressPreviewSurface(response: TaskBoardWorkerProgressPreviewFixture.early)
    .harnessPreviewSceneAppearance()
}

#Preview("Task Board Worker Progress — Awaiting Review") {
  TaskBoardWorkerProgressPreviewSurface(
    response: TaskBoardWorkerProgressPreviewFixture.awaitingReview
  )
  .harnessPreviewSceneAppearance()
}

#Preview("Task Board Worker Progress — Blocked") {
  TaskBoardWorkerProgressPreviewSurface(response: TaskBoardWorkerProgressPreviewFixture.blocked)
    .harnessPreviewSceneAppearance()
}

#Preview("Task Board Worker Progress — Not Dispatched") {
  TaskBoardWorkerProgressPreviewSurface(
    response: TaskBoardWorkItemProgressResponse()
  )
  .harnessPreviewSceneAppearance()
}

#Preview("Task Board Worker Progress — Largest Text") {
  TaskBoardWorkerProgressPreviewSurface(response: TaskBoardWorkerProgressPreviewFixture.running)
    .harnessPreviewSceneAppearance(
      textSizeIndex: HarnessMonitorTextSize.scales.count - 1
    )
}

@MainActor
private struct TaskBoardWorkerProgressPreviewSurface: View {
  let response: TaskBoardWorkItemProgressResponse
  // Pinned rather than live: the checkpoint log renders relative ages, so a
  // real `.now` would make every rendered snapshot differ from the last.
  @State private var relativeTimeClock = TaskBoardRelativeTimeClock(
    referenceDate: TaskBoardWorkerProgressPreviewFixture.referenceDate
  )

  var body: some View {
    TaskBoardItemWorkerProgressSection(
      item: TaskBoardWorkerProgressPreviewFixture.item,
      actions: TaskBoardOverviewActions(store: nil, scope: .dashboard),
      state: TaskBoardWorkerProgressState(response: response)
    )
    .padding(24)
    .frame(width: 600, alignment: .topLeading)
    .background(Color(nsColor: .windowBackgroundColor))
    .environment(relativeTimeClock)
  }
}

private enum TaskBoardWorkerProgressPreviewFixture {
  /// Six minutes after the newest checkpoint, so the log shows a readable
  /// spread of ages instead of everything collapsing to "just now".
  @MainActor static let referenceDate =
    TaskBoardCardDateParsing.parse("2026-08-08T09:20:00Z") ?? .now

  static let workItemID = "task-board-0f2c11a4"

  static let item = TaskBoardItem(
    schemaVersion: 1,
    id: "worker-progress-preview",
    title: "Report worker progress without Sessions",
    body: "Own worker progress on the board rather than mirroring a Session task",
    status: .inProgress,
    priority: .high,
    tags: ["task-board", "daemon"],
    projectId: "harness",
    agentMode: .headless,
    workflowKind: .defaultTask,
    externalRefs: [],
    planning: TaskBoardPlanningState(),
    workflow: TaskBoardWorkflowState(
      executionId: "workflow-0f2c11a4",
      status: .running,
      currentStepId: "worker",
      attempts: 1
    ),
    sessionId: nil,
    workItemId: workItemID,
    usage: TaskBoardUsage(),
    createdAt: "2026-08-08T09:00:00Z",
    updatedAt: "2026-08-08T09:14:30Z",
    deletedAt: nil
  )

  static let early = response(
    state: .running,
    percent: 15,
    summary: "Reproduced the drift with the smallest focused test",
    blockedReason: nil,
    completedAt: nil
  )

  static let running = response(
    state: .running,
    percent: 60,
    summary: "Reworked the settlement path and reran the focused tests",
    blockedReason: nil,
    completedAt: nil
  )

  static let awaitingReview = response(
    state: .awaitingReview,
    percent: 100,
    summary: "Ready for review; the focused gate is green",
    blockedReason: nil,
    completedAt: nil
  )

  static let blocked = response(
    state: .blocked,
    percent: nil,
    summary: nil,
    blockedReason: "The worktree was unchanged, so completion could not be evidenced",
    completedAt: "2026-08-08T09:14:30Z"
  )

  private static func response(
    state: TaskBoardWorkItemState,
    percent: UInt8?,
    summary: String?,
    blockedReason: String?,
    completedAt: String?
  ) -> TaskBoardWorkItemProgressResponse {
    TaskBoardWorkItemProgressResponse(
      progress: TaskBoardWorkItemProgress(
        boardItemId: item.id,
        workItemId: workItemID,
        executionId: "workflow-0f2c11a4",
        state: state,
        progressPercent: percent,
        summary: summary,
        blockedReason: blockedReason,
        attemptId: "codex-dispatch-intent-0f2c11a4",
        itemRevision: 7,
        reportSequence: 4,
        checkpoints: checkpoints(for: state),
        createdAt: "2026-08-08T09:00:00Z",
        updatedAt: "2026-08-08T09:14:30Z",
        completedAt: completedAt
      )
    )
  }

  /// The last checkpoint tracks the state so a blocked fixture does not close
  /// its log claiming a green gate.
  private static func checkpoints(
    for state: TaskBoardWorkItemState
  ) -> [TaskBoardWorkItemCheckpoint] {
    [
      TaskBoardWorkItemCheckpoint(
        checkpointId: "work-item-checkpoint-1",
        sequence: 1,
        actor: "codex-worker",
        summary: "Reproduced the drift with the smallest focused test",
        progressPercent: 20,
        attemptId: "codex-dispatch-intent-0f2c11a4",
        recordedAt: "2026-08-08T09:04:10Z"
      ),
      TaskBoardWorkItemCheckpoint(
        checkpointId: "work-item-checkpoint-2",
        sequence: 2,
        actor: "codex-worker",
        summary: "Moved the record and the lane into one transaction",
        progressPercent: 45,
        attemptId: "codex-dispatch-intent-0f2c11a4",
        recordedAt: "2026-08-08T09:09:02Z"
      ),
      TaskBoardWorkItemCheckpoint(
        checkpointId: "work-item-checkpoint-3",
        sequence: 3,
        actor: "codex-worker",
        summary: state == .blocked
          ? "Reran the owning gate; it reported no change to evidence"
          : "Reran the owning gate and it came back green",
        progressPercent: state == .blocked ? 45 : 60,
        attemptId: "codex-dispatch-intent-0f2c11a4",
        recordedAt: "2026-08-08T09:14:30Z"
      ),
    ]
  }
}

@MainActor
public enum TaskBoardWorkerProgressPreviewRenderer {
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
      name: "worker-progress-early",
      textSizeIndex: HarnessMonitorTextSize.defaultIndex,
      content: TaskBoardWorkerProgressPreviewSurface(
        response: TaskBoardWorkerProgressPreviewFixture.early
      ),
      directory: directory
    )
      && render(
        name: "worker-progress-running",
        textSizeIndex: HarnessMonitorTextSize.defaultIndex,
        content: TaskBoardWorkerProgressPreviewSurface(
          response: TaskBoardWorkerProgressPreviewFixture.running
        ),
        directory: directory
      )
      && render(
        name: "worker-progress-awaiting-review",
        textSizeIndex: HarnessMonitorTextSize.defaultIndex,
        content: TaskBoardWorkerProgressPreviewSurface(
          response: TaskBoardWorkerProgressPreviewFixture.awaitingReview
        ),
        directory: directory
      )
      && render(
        name: "worker-progress-blocked",
        textSizeIndex: HarnessMonitorTextSize.defaultIndex,
        content: TaskBoardWorkerProgressPreviewSurface(
          response: TaskBoardWorkerProgressPreviewFixture.blocked
        ),
        directory: directory
      )
      && render(
        name: "worker-progress-not-dispatched",
        textSizeIndex: HarnessMonitorTextSize.defaultIndex,
        content: TaskBoardWorkerProgressPreviewSurface(
          response: TaskBoardWorkItemProgressResponse()
        ),
        directory: directory
      )
      && render(
        name: "worker-progress-largest-text",
        textSizeIndex: HarnessMonitorTextSize.scales.count - 1,
        content: TaskBoardWorkerProgressPreviewSurface(
          response: TaskBoardWorkerProgressPreviewFixture.running
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
    let height = max(view.fittingSize.height, 1)
    view.setFrameSize(NSSize(width: 600, height: height))
    view.layoutSubtreeIfNeeded()
    guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      return false
    }
    view.cacheDisplay(in: view.bounds, to: representation)
    guard let data = representation.representation(using: .png, properties: [:]) else {
      return false
    }
    let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
    do {
      try data.write(to: url)
    } catch {
      return false
    }
    return true
  }
}
