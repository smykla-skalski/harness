import Foundation
import HarnessMonitorPolicyModels

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

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case revision
    case mode
    case nodes
    case edges
    case groups
    case layout
    case policyTraceIds = "policy_trace_ids"
  }

  public func supervisorPolicyOverrides() -> [PolicyConfigOverride] {
    nodes.compactMap { node in
      // The wire model identifies a supervisor rule by the node id (the seed
      // builds supervisor nodes as `node(id, id, ...)`), so the node id is the
      // rule identity the registry overrides are keyed on.
      guard case let .supervisorRule(decision, _) = node.kind else {
        return nil
      }
      return PolicyConfigOverride(
        ruleID: node.id,
        enabled: decision != .deny,
        defaultBehavior: .cautious,
        parameters: [
          "policy_canvas_node_id": node.id,
          "policy_canvas_revision": String(revision),
          "policy_canvas_decision": decision.rawValue,
        ]
      )
    }
  }
}

public struct TaskBoardPolicyPipelineNode: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var label: String
  public var kind: PolicyGraphNodeKind
  public var automation: PolicyGraphAutomationBinding?
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
    kind: PolicyGraphNodeKind,
    automation: PolicyGraphAutomationBinding? = nil,
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
    kind: PolicyGraphNodeKind,
    automation: PolicyGraphAutomationBinding? = nil,
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
    case inputPorts = "input_ports"
    case outputPorts = "output_ports"
    case groupId = "group_id"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    label = try container.decode(String.self, forKey: .label)
    kind = try container.decode(PolicyGraphNodeKind.self, forKey: .kind)
    automation = try container.decodeIfPresent(
      PolicyGraphAutomationBinding.self,
      forKey: .automation
    )
    inputPorts = try container.decodeIfPresent([String].self, forKey: .inputPorts) ?? []
    outputPorts = try container.decodeIfPresent([String].self, forKey: .outputPorts) ?? []
    groupId = try container.decodeIfPresent(String.self, forKey: .groupId)
    position = .zero
  }
}
