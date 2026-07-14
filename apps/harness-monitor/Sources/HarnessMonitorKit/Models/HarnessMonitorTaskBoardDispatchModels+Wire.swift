import Foundation
import HarnessMonitorPolicyModels

// Map the generated dispatch wire graph to the rich hand models. The internally-tagged
// wire enums (readiness, block-reason, session-intent, policy-decision) flatten into the
// hand discriminator structs - a `state`/`kind`/`decision` String plus the variant fields
// as optionals (the hand drops the machine-mismatch fields). The daemon's lifecycle and
// failures are already absent from the wire; PolicyDecision/PolicyReasonCode come from
// HarnessMonitorPolicyModels.

extension PolicySimulationDecision {
  public init(wire: PolicyDecision) {
    switch wire {
    case .allow(let reasonCode, let policyVersion):
      self.init(decision: "allow", reasonCode: reasonCode.rawValue, policyVersion: policyVersion)
    case .deny(let reasonCode, let policyVersion):
      self.init(decision: "deny", reasonCode: reasonCode.rawValue, policyVersion: policyVersion)
    case .requireHuman(let reasonCode, let policyVersion):
      self.init(
        decision: "require_human", reasonCode: reasonCode.rawValue, policyVersion: policyVersion
      )
    case .requireConsensus(let reasonCode, let policyVersion):
      self.init(
        decision: "require_consensus", reasonCode: reasonCode.rawValue, policyVersion: policyVersion
      )
    case .dryRunOnly(let reasonCode, let policyVersion):
      self.init(
        decision: "dry_run_only", reasonCode: reasonCode.rawValue, policyVersion: policyVersion
      )
    }
  }
}

extension TaskBoardDispatchBlockReason {
  public init(wire: DispatchBlockReasonWire) {
    switch wire {
    case .alreadyLinked(let workItemId):
      self.init(
        kind: "already_linked", workItemId: workItemId, reason: nil, decision: nil, status: nil)
    case .deleted:
      self.init(kind: "deleted", workItemId: nil, reason: nil, decision: nil, status: nil)
    case .machineMismatch:
      self.init(kind: "machine_mismatch", workItemId: nil, reason: nil, decision: nil, status: nil)
    case .planApproval(let reason):
      self.init(
        kind: "plan_approval",
        workItemId: nil,
        reason: TaskBoardPlanApprovalBlockReason(rawValue: reason.rawValue),
        decision: nil,
        status: nil
      )
    case .policy(let decision):
      self.init(
        kind: "policy",
        workItemId: nil,
        reason: nil,
        decision: PolicySimulationDecision(wire: decision),
        status: nil
      )
    case .status(let status):
      self.init(kind: "status", workItemId: nil, reason: nil, decision: nil, status: status)
    }
  }
}

extension TaskBoardDispatchReadiness {
  public init(wire: DispatchReadinessWire) {
    switch wire {
    case .ready:
      self.init(state: "ready", reason: nil)
    case .blocked(let reason):
      self.init(state: "blocked", reason: TaskBoardDispatchBlockReason(wire: reason))
    }
  }
}

extension TaskBoardSessionIntent {
  public init(wire: SessionIntentWire) {
    switch wire {
    case .existing(let sessionId):
      self.init(kind: "existing", sessionId: sessionId, title: nil, context: nil, projectId: nil)
    case .create(let title, let context, let projectId):
      self.init(
        kind: "create", sessionId: nil, title: title, context: context, projectId: projectId)
    }
  }
}

extension TaskBoardTaskCreationIntent {
  public init(wire: TaskCreationIntentWire) {
    self.init(
      title: wire.title,
      context: wire.context,
      severity: wire.severity,
      suggestedFix: wire.suggestedFix,
      source: wire.source,
      tags: wire.tags,
      externalRefs: wire.externalRefs.map(TaskBoardExternalRef.init(wire:))
    )
  }
}

extension TaskBoardWorkerIntent {
  public init(wire: WorkerIntentWire) {
    self.init(mode: wire.mode)
  }
}

extension TaskBoardReviewerIntent {
  public init(wire: ReviewerIntentWire) {
    self.init(
      phase: wire.phase.rawValue,
      suggestedPersona: wire.suggestedPersona,
      requiredConsensus: wire.requiredConsensus
    )
  }
}

extension TaskBoardEvaluatorIntent {
  public init(wire: EvaluatorIntentWire) {
    self.init(phase: wire.phase.rawValue, mode: wire.mode)
  }
}

extension TaskBoardDispatchPlan {
  public init(wire: DispatchPlanWire) {
    self.init(
      boardItemId: wire.boardItemId,
      renderedPrompt: wire.renderedPrompt,
      readiness: TaskBoardDispatchReadiness(wire: wire.readiness),
      session: TaskBoardSessionIntent(wire: wire.session),
      task: TaskBoardTaskCreationIntent(wire: wire.task),
      worker: TaskBoardWorkerIntent(wire: wire.worker),
      reviewer: TaskBoardReviewerIntent(wire: wire.reviewer),
      evaluator: TaskBoardEvaluatorIntent(wire: wire.evaluator),
      policy: PolicySimulationDecision(wire: wire.policy),
      policyDecisionId: wire.policyDecisionId,
      consumedApprovalGrantId: wire.consumedApprovalGrantId
    )
  }
}

extension TaskBoardDispatchAppliedTask {
  public init(wire: DispatchAppliedTaskWire) {
    self.init(
      boardItemId: wire.boardItemId,
      sessionId: wire.sessionId,
      workItemId: wire.workItemId,
      item: TaskBoardItem(wire: wire.item)
    )
  }
}

extension TaskBoardDispatchSummary {
  public init(wire: DispatchExecutionSummaryWire) {
    self.init(
      plans: wire.plans.map(TaskBoardDispatchPlan.init(wire:)),
      applied: wire.applied.map(TaskBoardDispatchAppliedTask.init(wire:))
    )
  }
}
