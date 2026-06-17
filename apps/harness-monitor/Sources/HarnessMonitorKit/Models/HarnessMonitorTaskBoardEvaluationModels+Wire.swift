import Foundation

// Map the generated evaluation wire types to the rich hand models. The record carries
// a TaskBoardItemWire (item wire/model split) and references TaskStatus/TaskBoardStatus
// bare; the workflow status maps from its *Wire enum. The hand summary uses Int counts
// and drops the daemon signal_failures (not surfaced in the app).

extension TaskBoardEvaluationOutcome {
  public init(wire: TaskBoardEvaluationOutcomeWire) {
    self =
      switch wire {
      case .skippedUnlinked: .skippedUnlinked
      case .missingSession: .missingSession
      case .missingTask: .missingTask
      case .workerPending: .workerPending
      case .workerRunning: .workerRunning
      case .reviewPending: .reviewPending
      case .reviewRunning: .reviewRunning
      case .reviewChangesRequested: .reviewChangesRequested
      case .completed: .completed
      case .blocked: .blocked
      }
  }
}

extension TaskBoardWorkflowStatus {
  public init(wire: TaskBoardWorkflowStatusWire) {
    self =
      switch wire {
      case .idle: .idle
      case .running: .running
      case .paused: .paused
      case .completed: .completed
      case .failed: .failed
      case .cancelled: .cancelled
      }
  }
}

extension TaskBoardEvaluationRecord {
  public init(wire: TaskBoardEvaluationRecordWire) {
    self.init(
      boardItemId: wire.boardItemId,
      sessionId: wire.sessionId,
      workItemId: wire.workItemId,
      outcome: TaskBoardEvaluationOutcome(wire: wire.outcome),
      taskStatus: wire.taskStatus,
      boardStatus: wire.boardStatus,
      workflowStatus: wire.workflowStatus.map(TaskBoardWorkflowStatus.init(wire:)),
      updated: wire.updated,
      reason: wire.reason,
      item: wire.item.map(TaskBoardItem.init(wire:))
    )
  }
}

extension TaskBoardEvaluationSummary {
  public init(wire: TaskBoardEvaluationSummaryWire) {
    self.init(
      total: Int(wire.total),
      evaluated: Int(wire.evaluated),
      updated: Int(wire.updated),
      skipped: Int(wire.skipped),
      completed: Int(wire.completed),
      running: Int(wire.running),
      reviewing: Int(wire.reviewing),
      blocked: Int(wire.blocked),
      failed: Int(wire.failed),
      records: wire.records.map(TaskBoardEvaluationRecord.init(wire:))
    )
  }
}
