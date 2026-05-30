import Foundation

public struct TaskBoardPolicyPipelineNodeKind: Codable, Equatable, Sendable {
  public var kind: String
  public var workflow: String?
  public var workflowId: String?
  public var action: TaskBoardPolicyAction?
  public var actionId: String?
  public var actions: [TaskBoardPolicyAction]
  public var checks: [TaskBoardPolicyEvidenceCheck]
  public var field: TaskBoardPolicyEvidenceField?
  public var predicate: TaskBoardPolicyEvidencePredicate?
  public var threshold: UInt8?
  public var ruleId: String?
  public var wait: TaskBoardPolicyWaitCondition?
  public var resumeKey: String?
  public var eventKey: String?
  public var handoffKey: String?
  public var reasonCode: String?
  public var reasonCodes: [String]
  public var decision: String?
  public var highRiskReasonCode: String?
  public var missingReasonCode: String?

  public init(
    kind: String,
    workflow: String? = nil,
    workflowId: String? = nil,
    action: TaskBoardPolicyAction? = nil,
    actionId: String? = nil,
    actions: [TaskBoardPolicyAction] = [],
    checks: [TaskBoardPolicyEvidenceCheck] = [],
    field: TaskBoardPolicyEvidenceField? = nil,
    predicate: TaskBoardPolicyEvidencePredicate? = nil,
    threshold: UInt8? = nil,
    ruleId: String? = nil,
    wait: TaskBoardPolicyWaitCondition? = nil,
    resumeKey: String? = nil,
    eventKey: String? = nil,
    handoffKey: String? = nil,
    reasonCode: String? = nil,
    reasonCodes: [String] = [],
    decision: String? = nil,
    highRiskReasonCode: String? = nil,
    missingReasonCode: String? = nil
  ) {
    self.kind = kind
    self.workflow = workflow
    self.workflowId = workflowId
    self.action = action
    self.actionId = actionId
    self.actions = actions
    self.checks = checks
    self.field = field
    self.predicate = predicate
    self.threshold = threshold
    self.ruleId = ruleId
    self.wait = wait
    self.resumeKey = resumeKey
    self.eventKey = eventKey
    self.handoffKey = handoffKey
    self.reasonCode = reasonCode
    self.reasonCodes = reasonCodes
    self.decision = decision
    self.highRiskReasonCode = highRiskReasonCode
    self.missingReasonCode = missingReasonCode
  }

  enum CodingKeys: String, CodingKey {
    case kind
    case workflow
    case workflowId
    case action
    case actionId
    case actions
    case checks
    case field
    case predicate
    case threshold
    case ruleId
    case wait
    case resumeKey
    case eventKey
    case handoffKey
    case reasonCode
    case reasonCodes
    case decision
    case highRiskReasonCode
    case missingReasonCode
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    kind = try container.decode(String.self, forKey: .kind)
    workflow = try container.decodeIfPresent(String.self, forKey: .workflow)
    workflowId = try container.decodeIfPresent(String.self, forKey: .workflowId)
    action = try container.decodeIfPresent(TaskBoardPolicyAction.self, forKey: .action)
    actionId = try container.decodeIfPresent(String.self, forKey: .actionId)
    actions = try container.decodeIfPresent([TaskBoardPolicyAction].self, forKey: .actions) ?? []
    if actions.isEmpty, let action {
      actions = [action]
    }
    checks =
      try container.decodeIfPresent([TaskBoardPolicyEvidenceCheck].self, forKey: .checks) ?? []
    field = try container.decodeIfPresent(TaskBoardPolicyEvidenceField.self, forKey: .field)
    predicate = try container.decodeIfPresent(
      TaskBoardPolicyEvidencePredicate.self,
      forKey: .predicate
    )
    threshold = try container.decodeIfPresent(UInt8.self, forKey: .threshold)
    ruleId = try container.decodeIfPresent(String.self, forKey: .ruleId)
    wait = try container.decodeIfPresent(TaskBoardPolicyWaitCondition.self, forKey: .wait)
    resumeKey = try container.decodeIfPresent(String.self, forKey: .resumeKey)
    eventKey = try container.decodeIfPresent(String.self, forKey: .eventKey)
    handoffKey = try container.decodeIfPresent(String.self, forKey: .handoffKey)
    reasonCode = try container.decodeIfPresent(String.self, forKey: .reasonCode)
    reasonCodes = try container.decodeIfPresent([String].self, forKey: .reasonCodes) ?? []
    decision = try container.decodeIfPresent(String.self, forKey: .decision)
    highRiskReasonCode = try container.decodeIfPresent(String.self, forKey: .highRiskReasonCode)
    missingReasonCode = try container.decodeIfPresent(String.self, forKey: .missingReasonCode)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    try container.encodeIfPresent(workflow, forKey: .workflow)
    try container.encodeIfPresent(workflowId, forKey: .workflowId)
    let effectiveActions = actions.isEmpty ? action.map { [$0] } ?? [] : actions
    if !effectiveActions.isEmpty {
      try container.encode(effectiveActions, forKey: .actions)
    }
    try container.encodeIfPresent(actionId, forKey: .actionId)
    if !checks.isEmpty {
      try container.encode(checks, forKey: .checks)
    }
    try container.encodeIfPresent(field, forKey: .field)
    try container.encodeIfPresent(predicate, forKey: .predicate)
    try container.encodeIfPresent(threshold, forKey: .threshold)
    try container.encodeIfPresent(ruleId, forKey: .ruleId)
    try container.encodeIfPresent(wait, forKey: .wait)
    try container.encodeIfPresent(resumeKey, forKey: .resumeKey)
    try container.encodeIfPresent(eventKey, forKey: .eventKey)
    try container.encodeIfPresent(handoffKey, forKey: .handoffKey)
    try container.encodeIfPresent(defaultReasonCode, forKey: .reasonCode)
    if !reasonCodes.isEmpty {
      try container.encode(reasonCodes, forKey: .reasonCodes)
    } else if kind == "supervisor_rule" {
      try container.encode(["default_allow"], forKey: .reasonCodes)
    }
    try container.encodeIfPresent(defaultDecision, forKey: .decision)
    try container.encodeIfPresent(highRiskReasonCode, forKey: .highRiskReasonCode)
    try container.encodeIfPresent(missingReasonCode, forKey: .missingReasonCode)
  }

  private var defaultReasonCode: String? {
    if let reasonCode {
      return reasonCode
    }
    switch kind {
    case "human_gate":
      return "human_required"
    case "consensus_gate":
      return "protected_path_touched"
    case "dry_run_gate":
      return "dry_run_required"
    case "finish":
      return "policy_finished"
    default:
      return nil
    }
  }

  private var defaultDecision: String? {
    if let decision {
      return decision
    }
    return kind == "supervisor_rule" || kind == "finish" ? "allow" : nil
  }
}
