import Foundation

// Maps the reviews-policy TUI cluster - preview / start / status / history - to
// the generated wire types in Models/Generated/ReviewsTypesWireTypes.generated
// .swift. This finishes the reviews subsystem reroute. The policy enums
// (ReviewsPolicyTrigger / ReviewsPolicyRunStatus / ReviewsPolicyStepType) are
// open TaskBoardOpenEnum on the hand side but closed *Wire enums on the wire, so
// they convert through rawValue (open init never fails). The counts and
// durationSeconds narrow from the wire's unsigned types to the hand Int, and the
// preview/status responses intentionally drop the wire workflowId/subject the
// hand models never carried. Request targets reuse ReviewTargetWire from the
// action cluster.

extension ReviewsPolicySubject {
  init(wire: ReviewsPolicySubjectWire) {
    self.init(repository: wire.repository, pullRequestNumber: wire.pullRequestNumber)
  }
}

extension ReviewsPolicySubjectWire {
  init(_ model: ReviewsPolicySubject) {
    self.init(repository: model.repository, pullRequestNumber: model.pullRequestNumber)
  }
}

extension ReviewsPolicyWait {
  init(wire: ReviewsPolicyWaitWire) {
    self.init(eventKey: wire.eventKey, durationSeconds: wire.durationSeconds.map { Int($0) })
  }
}

extension ReviewsPolicyPreviewStep {
  init(wire: ReviewsPolicyPreviewStepWire) {
    self.init(
      stepType: ReviewsPolicyStepType(rawValue: wire.stepType.rawValue),
      actionKey: wire.actionKey,
      waitingOn: wire.waitingOn.map(ReviewsPolicyWait.init(wire:))
    )
  }
}

extension ReviewsPolicyPreviewResponse {
  init(wire: ReviewsPolicyPreviewResponseWire) {
    self.init(
      eligible: wire.eligible,
      reason: wire.reason,
      steps: wire.steps.map(ReviewsPolicyPreviewStep.init(wire:)),
      warnings: wire.warnings
    )
  }
}

extension ReviewsPolicyPreviewRequestWire {
  init(_ model: ReviewsPolicyPreviewRequest) {
    self.init(
      workflowId: model.workflowID,
      target: ReviewTargetWire(model.target),
      method: model.method
    )
  }
}

extension ReviewsPolicyRunStep {
  init(wire: ReviewsPolicyRunStepWire) {
    self.init(
      stepType: ReviewsPolicyStepType(rawValue: wire.stepType.rawValue),
      actionKey: wire.actionKey,
      waitingOn: wire.waitingOn.map(ReviewsPolicyWait.init(wire:)),
      recordedAt: wire.recordedAt
    )
  }
}

extension ReviewsPolicyRunResponse {
  init(wire: ReviewsPolicyRunResponseWire) {
    self.init(
      runID: wire.runId,
      workflowID: wire.workflowId,
      subject: ReviewsPolicySubject(wire: wire.subject),
      trigger: ReviewsPolicyTrigger(rawValue: wire.trigger.rawValue),
      status: ReviewsPolicyRunStatus(rawValue: wire.status.rawValue),
      startedAt: wire.startedAt,
      updatedAt: wire.updatedAt,
      waitingOn: wire.waitingOn.map(ReviewsPolicyWait.init(wire:)),
      completedAt: wire.completedAt,
      errorMessage: wire.errorMessage,
      steps: wire.steps.map(ReviewsPolicyRunStep.init(wire:))
    )
  }
}

extension ReviewsPolicyRunStartRequestWire {
  init(_ model: ReviewsPolicyRunStartRequest) {
    self.init(
      workflowId: model.workflowID,
      target: ReviewTargetWire(model.target),
      method: model.method,
      trigger: ReviewsPolicyTriggerWire(rawValue: model.trigger.rawValue) ?? .manual
    )
  }
}

extension ReviewsPolicyStatusResponse {
  init(wire: ReviewsPolicyStatusResponseWire) {
    self.init(
      activeRun: wire.activeRun.map(ReviewsPolicyRunResponse.init(wire:)),
      recentRuns: wire.recentRuns.map(ReviewsPolicyRunResponse.init(wire:))
    )
  }
}

extension ReviewsPolicyStatusRequestWire {
  init(_ model: ReviewsPolicyStatusRequest) {
    self.init(workflowId: model.workflowID, subject: ReviewsPolicySubjectWire(model.subject))
  }
}

extension ReviewsPolicyRunMetrics {
  init(wire: ReviewsPolicyRunMetricsWire) {
    self.init(
      total: Int(wire.total),
      running: Int(wire.running),
      waiting: Int(wire.waiting),
      completed: Int(wire.completed),
      failed: Int(wire.failed),
      cancelled: Int(wire.cancelled),
      byTrigger: wire.byTrigger.mapValues { Int($0) }
    )
  }
}

extension ReviewsPolicyTimelineEntry {
  init(wire: ReviewsPolicyTimelineEntryWire) {
    self.init(recordedAt: wire.recordedAt, runID: wire.runId, event: wire.event)
  }
}

extension ReviewsPolicyHistoryResponse {
  init(wire: ReviewsPolicyHistoryResponseWire) {
    self.init(
      workflowID: wire.workflowId,
      subject: ReviewsPolicySubject(wire: wire.subject),
      runs: wire.runs.map(ReviewsPolicyRunResponse.init(wire:)),
      metrics: ReviewsPolicyRunMetrics(wire: wire.metrics),
      timeline: wire.timeline.map(ReviewsPolicyTimelineEntry.init(wire:))
    )
  }
}

extension ReviewsPolicyHistoryRequestWire {
  init(_ model: ReviewsPolicyHistoryRequest) {
    self.init(workflowId: model.workflowID, subject: ReviewsPolicySubjectWire(model.subject))
  }
}
