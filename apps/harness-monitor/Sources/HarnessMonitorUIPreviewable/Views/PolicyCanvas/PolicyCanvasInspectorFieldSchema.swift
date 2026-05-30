import HarnessMonitorKit

/// The vocabulary of editable inspector fields a policy node can expose. Each
/// case is a reusable, typed control; node kinds compose them via
/// `PolicyCanvasInspectorFieldSchema`. A node kind that reuses existing fields
/// needs only a schema entry, not a bespoke per-kind form builder.
enum PolicyInspectorField: String, CaseIterable, Identifiable {
  case workflow
  case workflowID
  case actionBinding
  case actionID
  case evidenceField
  case evidenceChecks
  case conditionPredicate
  case switchCases
  case riskThreshold
  case waitKind
  case waitDuration
  case waitEventKey
  case resumeKey
  case eventKey
  case handoffKey
  case reasonCode
  case ruleID
  case gateDecision
  case finishDecision

  var id: String { rawValue }

  /// Label shown on the inspector row that wraps the control.
  var rowLabel: String {
    switch self {
    case .workflow: "Workflow"
    case .workflowID: "Workflow id"
    case .actionBinding: "Action"
    case .actionID: "Action id"
    case .evidenceField: "Evidence"
    case .evidenceChecks: "Checks"
    case .conditionPredicate: "Condition"
    case .switchCases: "Cases"
    case .riskThreshold: "Risk"
    case .waitKind: "Wait kind"
    case .waitDuration: "Duration"
    case .waitEventKey: "Event key"
    case .resumeKey: "Resume key"
    case .eventKey: "Event key"
    case .handoffKey: "Handoff key"
    case .reasonCode: "Reason"
    case .ruleID: "Rule"
    case .gateDecision: "Decision"
    case .finishDecision: "Decision"
    }
  }

  /// Stable accessibility key passed to
  /// `HarnessMonitorAccessibility.policyCanvasInspectorField`.
  var accessibilityKey: String {
    switch self {
    case .workflow: "workflow"
    case .workflowID: "workflow-id"
    case .actionBinding: "action-binding"
    case .actionID: "action-id"
    case .evidenceField: "evidence-field"
    case .evidenceChecks: "evidence-checks"
    case .conditionPredicate: "condition-predicate"
    case .switchCases: "switch-cases"
    case .riskThreshold: "risk-threshold"
    case .waitKind: "wait-kind"
    case .waitDuration: "wait-duration"
    case .waitEventKey: "wait-event-key"
    case .resumeKey: "resume-key"
    case .eventKey: "event-key"
    case .handoffKey: "handoff-key"
    case .reasonCode: "reason-code"
    case .ruleID: "rule-id"
    case .gateDecision: "gate-behavior"
    case .finishDecision: "finish-decision"
    }
  }
}

/// Maps each policy node kind to the ordered inspector fields it exposes. This
/// is the single source of truth for inspector form composition: the renderer
/// iterates the returned fields and dispatches each to its typed control, so a
/// new node kind is added here rather than as a bespoke per-kind form builder.
enum PolicyCanvasInspectorFieldSchema {
  static func fields(for policyKind: TaskBoardPolicyPipelineNodeKind) -> [PolicyInspectorField] {
    sourceFields(for: policyKind)
      ?? orchestrationFields(for: policyKind)
      ?? outcomeFields(for: policyKind)
      ?? []
  }

  private static func sourceFields(
    for policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> [PolicyInspectorField]? {
    switch policyKind.kind {
    case "trigger": [.workflow]
    case "workflow_entry": [.workflowID]
    case "action_gate": [.actionBinding]
    case "action_step": [.actionID]
    case "evidence_check": [.evidenceChecks]
    case "if_then_else": [.evidenceField, .conditionPredicate]
    case "switch": [.switchCases]
    case "risk_classifier": [.riskThreshold]
    default: nil
    }
  }

  private static func orchestrationFields(
    for policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> [PolicyInspectorField]? {
    switch policyKind.kind {
    case "wait_step": waitStepFields(for: policyKind)
    case "event_wait": [.eventKey]
    case "handoff": [.handoffKey]
    default: nil
    }
  }

  private static func outcomeFields(
    for policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> [PolicyInspectorField]? {
    switch policyKind.kind {
    case "human_gate", "consensus_gate", "dry_run_gate": [.reasonCode]
    case "supervisor_rule": [.ruleID, .gateDecision]
    case "finish": [.finishDecision, .reasonCode]
    default: nil
    }
  }

  /// A wait step always shows the kind picker and a resume key; the middle
  /// field depends on the chosen wait kind (timer -> duration, event -> event
  /// key). A nil wait defaults to the event branch, matching the inspector's
  /// prior `(wait?.kind ?? .event)` behavior.
  private static func waitStepFields(
    for policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> [PolicyInspectorField] {
    let isTimer = (policyKind.wait?.kind ?? .event) == .timer
    return [.waitKind, isTimer ? .waitDuration : .waitEventKey, .resumeKey]
  }
}
