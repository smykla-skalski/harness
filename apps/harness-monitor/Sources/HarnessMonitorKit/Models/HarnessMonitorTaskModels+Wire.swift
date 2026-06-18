import Foundation

// Wire maps for the SessionDetail.tasks member (WorkItem) and its note/checkpoint structs. The
// severity/status/queuePolicy/source enums are decoder-agnostic (the hand TaskStatus/TaskQueuePolicy
// keep their legacy-tolerant custom decode) and ride through bare; reviewRound/progress narrow
// UInt8 -> Int. The wire's observe_issue_id and deleted_at have no rich-model field and are dropped.

extension TaskNote {
  init(wire: TaskNoteWire) {
    self.init(timestamp: wire.timestamp, agentId: wire.agentId, text: wire.text)
  }
}

extension TaskCheckpointSummary {
  init(wire: TaskCheckpointSummaryWire) {
    self.init(
      checkpointId: wire.checkpointId,
      recordedAt: wire.recordedAt,
      actorId: wire.actorId,
      summary: wire.summary,
      progress: Int(wire.progress)
    )
  }
}

extension WorkItem {
  init(wire: WorkItemWire) {
    self.init(
      taskId: wire.taskId,
      title: wire.title,
      context: wire.context,
      severity: wire.severity,
      status: wire.status,
      assignedTo: wire.assignedTo,
      queuePolicy: wire.queuePolicy,
      queuedAt: wire.queuedAt,
      createdAt: wire.createdAt,
      updatedAt: wire.updatedAt,
      createdBy: wire.createdBy,
      notes: wire.notes.map(TaskNote.init(wire:)),
      suggestedFix: wire.suggestedFix,
      source: wire.source,
      blockedReason: wire.blockedReason,
      completedAt: wire.completedAt,
      checkpointSummary: wire.checkpointSummary.map(TaskCheckpointSummary.init(wire:)),
      awaitingReview: wire.awaitingReview.map(AwaitingReview.init(wire:)),
      reviewClaim: wire.reviewClaim.map(ReviewClaim.init(wire:)),
      consensus: wire.consensus.map(ReviewConsensus.init(wire:)),
      reviewRound: Int(wire.reviewRound),
      arbitration: wire.arbitration.map(ArbitrationOutcome.init(wire:)),
      suggestedPersona: wire.suggestedPersona,
      reviewHistory: wire.reviewHistory.map(ReviewConsensus.init(wire:))
    )
  }
}
