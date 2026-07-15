import HarnessMonitorPolicyModels

// Read-only payload projections for the wire node-kind enum. The inspector
// composes one typed control per `PolicyInspectorField`, and each control reads
// the value it edits out of the selected node's kind. The schema only surfaces a
// field for the kind that owns it (a `.workflow` row appears only on `.trigger`),
// so these projections return the payload when the matching case is active and a
// neutral default otherwise. They are deliberately read-only: every edit lands by
// reconstructing the faithful enum case in the commit funnel, never by writing a
// projected field. Mirrors the case-match helpers in
// `PolicyGraphNodeKind+Classification.swift`.
extension PolicyGraphNodeKind {
  public var workflow: String? {
    if case .trigger(let workflow) = self { return workflow }
    return nil
  }

  public var workflowId: String? {
    if case .workflowEntry(let entry) = self { return entry.workflowId }
    return nil
  }

  public var actionId: String? {
    if case .actionStep(let step) = self { return step.actionId }
    return nil
  }

  public var actions: [PolicyAction] {
    if case .actionGate(let actions) = self { return actions }
    return []
  }

  /// The evidence field an `if_then_else` or `risk_classifier` reads. An
  /// `evidence_check` carries its fields per check, so it projects `nil` here -
  /// its editor walks `checks` instead.
  public var field: PolicyEvidenceField? {
    switch self {
    case .ifThenElse(let condition): return condition.field
    case .riskClassifier(let field, _, _, _): return field
    default: return nil
    }
  }

  public var threshold: UInt8? {
    if case .riskClassifier(_, let threshold, _, _) = self { return threshold }
    return nil
  }

  public var predicate: PolicyEvidencePredicate? {
    if case .ifThenElse(let condition) = self { return condition.predicate }
    return nil
  }

  public var checks: [PolicyEvidenceCheck] {
    if case .evidenceCheck(let checks) = self { return checks }
    return []
  }

  public var arms: [PolicySwitchArm] {
    if case .switch(let node) = self { return node.arms }
    return []
  }

  /// The gate/terminal decision token, snake_case, for the decision picker. Both
  /// `supervisor_rule` and `finish` carry a decision; everything else is `nil`.
  public var decision: String? {
    switch self {
    case .supervisorRule(let decision, _): return decision.rawValue
    case .finish(let node): return node.decision.rawValue
    default: return nil
    }
  }

  /// The single reason code a gate or terminal emits, snake_case, for the reason
  /// text field. `supervisor_rule` keeps its codes in `reasonCodes`.
  public var reasonCode: String? {
    switch self {
    case .humanGate(let code), .consensusGate(let code), .dryRunGate(let code):
      return code.rawValue
    case .approvalGate(let gate):
      return gate.reasonCode.rawValue
    case .finish(let node):
      return node.reasonCode.rawValue
    default:
      return nil
    }
  }

  public var reasonCodes: [PolicyReasonCode] {
    if case .supervisorRule(_, let codes) = self { return codes }
    return []
  }

  public var resumeKey: String? {
    if case .waitStep(let step) = self { return step.resumeKey }
    return nil
  }

  public var eventKey: String? {
    if case .eventWait(let wait) = self { return wait.eventKey }
    return nil
  }

  public var handoffKey: String? {
    if case .handoff(let step) = self { return step.handoffKey }
    return nil
  }

  public var wait: PolicyWaitCondition? {
    if case .waitStep(let step) = self { return step.wait }
    return nil
  }
}

extension PolicyWaitCondition {
  /// Discriminator for the wait-kind segmented picker. The generated enum carries
  /// the payload per case; this projects just the branch so the picker has a
  /// `Hashable` selection without exposing the timer duration or event key.
  public enum Kind: Hashable {
    case timer
    case event
  }

  public var kind: Kind {
    switch self {
    case .timer: return .timer
    case .event: return .event
    }
  }

  public var durationSeconds: UInt64? {
    if case .timer(let durationSeconds) = self { return durationSeconds }
    return nil
  }

  public var eventKey: String? {
    if case .event(let eventKey) = self { return eventKey }
    return nil
  }
}
