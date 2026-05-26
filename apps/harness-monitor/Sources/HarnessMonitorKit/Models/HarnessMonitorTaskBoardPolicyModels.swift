import Foundation

public enum TaskBoardPolicyAction: String, Codable, CaseIterable, Identifiable, Sendable {
  case sync
  case triage
  case plan
  case spawnAgent = "spawn_agent"
  case mutateRepo = "mutate_repo"
  case pushBranch = "push_branch"
  case openPr = "open_pr"
  case submitReview = "submit_review"
  case mergePr = "merge_pr"
  case deleteWorktree = "delete_worktree"
  case stopAgent = "stop_agent"
  case accessSecret = "access_secret"
  case destructiveFs = "destructive_fs"

  public var id: String { rawValue }
}

public enum TaskBoardPolicyPipelineMode: String, Codable, CaseIterable, Sendable {
  case draft
  case dryRun = "dry_run"
  case enforced
}

public enum TaskBoardPolicyEvidenceField: String, Codable, CaseIterable, Sendable {
  case checksGreen = "checks_green"
  case branchProtectionAllowsMerge = "branch_protection_allows_merge"
  case reviewerVerdictApproved = "reviewer_verdict_approved"
  case unresolvedRequestedChanges = "unresolved_requested_changes"
  case protectedPathTouched = "protected_path_touched"
  case riskScore = "risk_score"
}

public struct TaskBoardPolicyPipelineDocument: Codable, Equatable, Sendable {
  public var schemaVersion: UInt16
  public var revision: UInt64
  public var mode: TaskBoardPolicyPipelineMode
  public var nodes: [TaskBoardPolicyPipelineNode]
  public var edges: [TaskBoardPolicyPipelineEdge]
  public var groups: [TaskBoardPolicyPipelineGroup]
  public var layout: TaskBoardPolicyPipelineLayout
  public var policyTraceIds: [String]

  public init(
    schemaVersion: UInt16 = 2,
    revision: UInt64,
    mode: TaskBoardPolicyPipelineMode,
    nodes: [TaskBoardPolicyPipelineNode],
    edges: [TaskBoardPolicyPipelineEdge],
    groups: [TaskBoardPolicyPipelineGroup],
    layout: TaskBoardPolicyPipelineLayout = TaskBoardPolicyPipelineLayout(),
    policyTraceIds: [String] = []
  ) {
    self.schemaVersion = schemaVersion
    self.revision = revision
    self.mode = mode
    self.nodes = nodes
    self.edges = edges
    self.groups = groups
    self.layout = layout
    self.policyTraceIds = policyTraceIds
  }

  public func supervisorPolicyOverrides() -> [PolicyConfigOverride] {
    nodes.compactMap { node in
      guard node.kind.kind == "supervisor_rule", let ruleID = node.kind.ruleId else {
        return nil
      }
      return PolicyConfigOverride(
        ruleID: ruleID,
        enabled: node.kind.decision != "deny",
        defaultBehavior: .cautious,
        parameters: [
          "policy_canvas_node_id": node.id,
          "policy_canvas_revision": String(revision),
          "policy_canvas_decision": node.kind.decision ?? "allow",
        ]
      )
    }
  }
}

public struct TaskBoardPolicyPipelineNode: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var label: String
  public var kind: TaskBoardPolicyPipelineNodeKind
  public var automation: TaskBoardPolicyPipelineAutomationBinding?
  public var inputPorts: [String]
  public var outputPorts: [String]
  public var groupId: String?
  public var position: TaskBoardPolicyCanvasPoint

  public var title: String {
    get { label }
    set { label = newValue }
  }

  public var inputs: [TaskBoardPolicyPipelinePort] {
    inputPorts.map { TaskBoardPolicyPipelinePort(id: $0, title: $0) }
  }

  public var outputs: [TaskBoardPolicyPipelinePort] {
    outputPorts.map { TaskBoardPolicyPipelinePort(id: $0, title: $0) }
  }

  public init(
    id: String,
    title: String,
    kind: TaskBoardPolicyPipelineNodeKind,
    automation: TaskBoardPolicyPipelineAutomationBinding? = nil,
    position: TaskBoardPolicyCanvasPoint = .zero,
    groupId: String? = nil,
    inputs: [TaskBoardPolicyPipelinePort] = [],
    outputs: [TaskBoardPolicyPipelinePort] = []
  ) {
    self.id = id
    self.label = title
    self.kind = kind
    self.automation = automation
    self.inputPorts = inputs.map(\.id)
    self.outputPorts = outputs.map(\.id)
    self.groupId = groupId
    self.position = position
  }

  public init(
    id: String,
    label: String,
    kind: TaskBoardPolicyPipelineNodeKind,
    automation: TaskBoardPolicyPipelineAutomationBinding? = nil,
    inputPorts: [String] = [],
    outputPorts: [String] = [],
    groupId: String? = nil
  ) {
    self.id = id
    self.label = label
    self.kind = kind
    self.automation = automation
    self.inputPorts = inputPorts
    self.outputPorts = outputPorts
    self.groupId = groupId
    self.position = .zero
  }

  enum CodingKeys: String, CodingKey {
    case id
    case label
    case kind
    case automation
    case inputPorts
    case outputPorts
    case groupId
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    label = try container.decode(String.self, forKey: .label)
    kind = try container.decode(TaskBoardPolicyPipelineNodeKind.self, forKey: .kind)
    automation = try container.decodeIfPresent(
      TaskBoardPolicyPipelineAutomationBinding.self,
      forKey: .automation
    )
    inputPorts = try container.decodeIfPresent([String].self, forKey: .inputPorts) ?? []
    outputPorts = try container.decodeIfPresent([String].self, forKey: .outputPorts) ?? []
    groupId = try container.decodeIfPresent(String.self, forKey: .groupId)
    position = .zero
  }
}

public struct TaskBoardPolicyPipelineAutomationBinding: Codable, Equatable, Sendable {
  public var isEnabled: Bool
  public var eventSource: String
  public var priority: Int?
  public var contentKinds: [String]
  public var preprocessors: [String]
  public var actions: [String]
  public var postprocessors: [String]
  public var sourceAppMode: String
  public var allowedBundleIdentifiers: [String]
  public var deniedBundleIdentifiers: [String]

  public init(
    isEnabled: Bool = true,
    eventSource: String,
    priority: Int? = nil,
    contentKinds: [String] = [],
    preprocessors: [String] = [],
    actions: [String] = [],
    postprocessors: [String] = [],
    sourceAppMode: String = "allExceptDenied",
    allowedBundleIdentifiers: [String] = [],
    deniedBundleIdentifiers: [String] = []
  ) {
    self.isEnabled = isEnabled
    self.eventSource = eventSource
    self.priority = priority
    self.contentKinds = contentKinds
    self.preprocessors = preprocessors
    self.actions = actions
    self.postprocessors = postprocessors
    self.sourceAppMode = sourceAppMode
    self.allowedBundleIdentifiers = allowedBundleIdentifiers
    self.deniedBundleIdentifiers = deniedBundleIdentifiers
  }

  enum CodingKeys: String, CodingKey {
    case isEnabled
    case eventSource
    case priority
    case contentKinds
    case preprocessors
    case actions
    case postprocessors
    case sourceAppMode
    case allowedBundleIdentifiers
    case deniedBundleIdentifiers
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    eventSource = try container.decodeIfPresent(String.self, forKey: .eventSource) ?? "clipboard"
    priority = try container.decodeIfPresent(Int.self, forKey: .priority)
    contentKinds = try container.decodeIfPresent([String].self, forKey: .contentKinds) ?? []
    preprocessors = try container.decodeIfPresent([String].self, forKey: .preprocessors) ?? []
    actions = try container.decodeIfPresent([String].self, forKey: .actions) ?? []
    postprocessors = try container.decodeIfPresent([String].self, forKey: .postprocessors) ?? []
    sourceAppMode =
      try container.decodeIfPresent(String.self, forKey: .sourceAppMode) ?? "allExceptDenied"
    allowedBundleIdentifiers =
      try container.decodeIfPresent([String].self, forKey: .allowedBundleIdentifiers) ?? []
    deniedBundleIdentifiers =
      try container.decodeIfPresent([String].self, forKey: .deniedBundleIdentifiers) ?? []
  }
}

public struct TaskBoardPolicyPipelineNodeKind: Codable, Equatable, Sendable {
  public var kind: String
  public var workflow: String?
  public var action: TaskBoardPolicyAction?
  public var actions: [TaskBoardPolicyAction]
  public var checks: [TaskBoardPolicyEvidenceCheck]
  public var field: TaskBoardPolicyEvidenceField?
  public var threshold: UInt8?
  public var ruleId: String?
  public var reasonCode: String?
  public var reasonCodes: [String]
  public var decision: String?
  public var highRiskReasonCode: String?
  public var missingReasonCode: String?

  public init(
    kind: String,
    workflow: String? = nil,
    action: TaskBoardPolicyAction? = nil,
    actions: [TaskBoardPolicyAction] = [],
    checks: [TaskBoardPolicyEvidenceCheck] = [],
    field: TaskBoardPolicyEvidenceField? = nil,
    threshold: UInt8? = nil,
    ruleId: String? = nil,
    reasonCode: String? = nil,
    reasonCodes: [String] = [],
    decision: String? = nil,
    highRiskReasonCode: String? = nil,
    missingReasonCode: String? = nil
  ) {
    self.kind = kind
    self.workflow = workflow
    self.action = action
    self.actions = actions
    self.checks = checks
    self.field = field
    self.threshold = threshold
    self.ruleId = ruleId
    self.reasonCode = reasonCode
    self.reasonCodes = reasonCodes
    self.decision = decision
    self.highRiskReasonCode = highRiskReasonCode
    self.missingReasonCode = missingReasonCode
  }

  enum CodingKeys: String, CodingKey {
    case kind
    case workflow
    case action
    case actions
    case checks
    case field
    case threshold
    case ruleId
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
    action = try container.decodeIfPresent(TaskBoardPolicyAction.self, forKey: .action)
    actions = try container.decodeIfPresent([TaskBoardPolicyAction].self, forKey: .actions) ?? []
    if actions.isEmpty, let action {
      actions = [action]
    }
    checks =
      try container.decodeIfPresent([TaskBoardPolicyEvidenceCheck].self, forKey: .checks) ?? []
    field = try container.decodeIfPresent(TaskBoardPolicyEvidenceField.self, forKey: .field)
    threshold = try container.decodeIfPresent(UInt8.self, forKey: .threshold)
    ruleId = try container.decodeIfPresent(String.self, forKey: .ruleId)
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
    let effectiveActions = actions.isEmpty ? action.map { [$0] } ?? [] : actions
    if !effectiveActions.isEmpty {
      try container.encode(effectiveActions, forKey: .actions)
    }
    if !checks.isEmpty {
      try container.encode(checks, forKey: .checks)
    }
    try container.encodeIfPresent(field, forKey: .field)
    try container.encodeIfPresent(threshold, forKey: .threshold)
    try container.encodeIfPresent(ruleId, forKey: .ruleId)
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
    default:
      return nil
    }
  }

  private var defaultDecision: String? {
    if let decision {
      return decision
    }
    return kind == "supervisor_rule" ? "allow" : nil
  }
}

public enum TaskBoardPolicyEvidencePredicateValue: String, Codable, CaseIterable, Sendable {
  case isTrue = "is_true"
  case isFalse = "is_false"
  case isZero = "is_zero"
}

public struct TaskBoardPolicyEvidencePredicate: Codable, Equatable, Sendable {
  public var predicate: TaskBoardPolicyEvidencePredicateValue

  public init(predicate: TaskBoardPolicyEvidencePredicateValue) {
    self.predicate = predicate
  }
}

public struct TaskBoardPolicyEvidenceCheck: Codable, Equatable, Sendable {
  public var field: TaskBoardPolicyEvidenceField
  public var pass: TaskBoardPolicyEvidencePredicate
  public var failReasonCode: String
  public var missingReasonCode: String

  public init(
    field: TaskBoardPolicyEvidenceField,
    pass: TaskBoardPolicyEvidencePredicate,
    failReasonCode: String,
    missingReasonCode: String
  ) {
    self.field = field
    self.pass = pass
    self.failReasonCode = failReasonCode
    self.missingReasonCode = missingReasonCode
  }
}
