import Foundation

extension PreviewHarnessClientState {
  func taskBoardItemProgress(id: String) throws -> TaskBoardWorkItemProgressResponse {
    _ = try currentTaskBoardItem(id: id)
    return taskBoardWorkItemProgressByItemID[id] ?? TaskBoardWorkItemProgressResponse()
  }

  /// Seeds a record for every item a worker would have been dispatched onto, so
  /// previews show the lane the fixture item already claims rather than an
  /// empty section.
  static func seededTaskBoardWorkItemProgress(
    items: [TaskBoardItem]
  ) -> [String: TaskBoardWorkItemProgressResponse] {
    Dictionary(
      uniqueKeysWithValues: items.compactMap { item in
        guard let workItemID = item.workItemId, !workItemID.isEmpty,
          let state = previewWorkItemState(for: item.status)
        else {
          return nil
        }
        return (
          item.id,
          TaskBoardWorkItemProgressResponse(
            progress: previewWorkItemProgress(item: item, workItemID: workItemID, state: state)
          )
        )
      }
    )
  }

  private static func previewWorkItemState(
    for status: TaskBoardStatus?
  ) -> TaskBoardWorkItemState? {
    switch status {
    case .inProgress: .running
    case .toReview: .awaitingReview
    case .inReview: .inReview
    case .failed: .blocked
    case .done: .done
    default: nil
    }
  }

  private static func previewWorkItemProgress(
    item: TaskBoardItem,
    workItemID: String,
    state: TaskBoardWorkItemState
  ) -> TaskBoardWorkItemProgress {
    let settled = state == .done || state == .blocked
    return TaskBoardWorkItemProgress(
      boardItemId: item.id,
      workItemId: workItemID,
      executionId: item.workflow?.executionId,
      state: state,
      progressPercent: state == .running ? 60 : nil,
      summary: previewSummary(for: state),
      blockedReason: state == .blocked ? item.workflow?.lastError : nil,
      attemptId: "codex-\(workItemID)",
      itemRevision: 4,
      reportSequence: 3,
      checkpoints: previewCheckpoints(workItemID: workItemID, state: state),
      createdAt: "2026-08-08T09:00:00Z",
      updatedAt: "2026-08-08T09:14:30Z",
      completedAt: settled ? "2026-08-08T09:14:30Z" : nil
    )
  }

  private static func previewSummary(for state: TaskBoardWorkItemState) -> String {
    switch state {
    case .pending: "Waiting for the worker to start."
    case .running: "Reworked the settlement path and reran the focused tests."
    case .awaitingReview: "Ready for review; the focused gate is green."
    case .inReview: "A reviewer has claimed the work."
    case .changesRequested: "The reviewer asked for one scoped fix."
    case .blocked: "Stopped without completion evidence."
    case .done: "Landed the change and reran the owning gate."
    }
  }

  private static func previewCheckpoints(
    workItemID: String,
    state: TaskBoardWorkItemState
  ) -> [TaskBoardWorkItemCheckpoint] {
    [
      TaskBoardWorkItemCheckpoint(
        checkpointId: "\(workItemID)-checkpoint-1",
        sequence: 1,
        actor: "codex-worker",
        summary: "Reproduced the failure with the smallest command.",
        progressPercent: 20,
        attemptId: "codex-\(workItemID)",
        recordedAt: "2026-08-08T09:04:10Z"
      ),
      TaskBoardWorkItemCheckpoint(
        checkpointId: "\(workItemID)-checkpoint-2",
        sequence: 2,
        actor: "codex-worker",
        summary: previewSummary(for: state),
        progressPercent: state == .running ? 60 : 100,
        attemptId: "codex-\(workItemID)",
        recordedAt: "2026-08-08T09:14:30Z"
      ),
    ]
  }
}
