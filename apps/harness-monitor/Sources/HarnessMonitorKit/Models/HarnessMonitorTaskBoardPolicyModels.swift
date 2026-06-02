import Foundation

public enum TaskBoardPolicyPipelineMode: String, Codable, CaseIterable, Sendable {
  case draft
  case dryRun = "dry_run"
  case enforced
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
