import Foundation
import HarnessMonitorPolicyModels

public enum PolicyPipelineMode: String, Codable, CaseIterable, Sendable {
  case draft
  case dryRun = "dry_run"
  case enforced
}

public struct PolicyPipelineDocument: Codable, Equatable, Sendable {
  public var schemaVersion: UInt16
  public var revision: UInt64
  public var mode: PolicyPipelineMode
  public var nodes: [PolicyPipelineNode]
  public var edges: [PolicyPipelineEdge]
  public var groups: [PolicyPipelineGroup]
  public var layout: PolicyPipelineLayout
  public var policyTraceIds: [String]

  public init(
    schemaVersion: UInt16 = 2,
    revision: UInt64,
    mode: PolicyPipelineMode,
    nodes: [PolicyPipelineNode],
    edges: [PolicyPipelineEdge],
    groups: [PolicyPipelineGroup],
    layout: PolicyPipelineLayout = PolicyPipelineLayout(),
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

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(UInt16.self, forKey: .schemaVersion)
    revision = try container.decode(UInt64.self, forKey: .revision)
    mode = try container.decode(PolicyPipelineMode.self, forKey: .mode)
    nodes = try container.decode([PolicyPipelineNode].self, forKey: .nodes)
    edges = try container.decode([PolicyPipelineEdge].self, forKey: .edges)
    groups = try container.decode([PolicyPipelineGroup].self, forKey: .groups)
    layout = try container.decode(PolicyPipelineLayout.self, forKey: .layout)
    policyTraceIds =
      try container.decodeIfPresent(
        [String].self,
        forKey: .policyTraceIds
      ) ?? []
  }

  public func supervisorPolicyOverrides() -> [PolicyConfigOverride] {
    nodes.compactMap { node in
      // The wire model identifies a supervisor rule by the node id (the seed
      // builds supervisor nodes as `node(id, id, ...)`), so the node id is the
      // rule identity the registry overrides are keyed on.
      guard case .supervisorRule(let decision, _) = node.kind else {
        return nil
      }
      return PolicyConfigOverride(
        ruleID: node.id.rawValue,
        enabled: decision != .deny,
        defaultBehavior: .cautious,
        parameters: [
          "policy_canvas_node_id": node.id.rawValue,
          "policy_canvas_revision": String(revision),
          "policy_canvas_decision": decision.rawValue,
        ]
      )
    }
  }
}

public struct PolicyPipelineNode: Codable, Equatable, Identifiable, Sendable {
  public var id: PolicyGraphNodeId
  public var label: String
  public var kind: PolicyGraphNodeKind
  public var automation: PolicyGraphAutomationBinding?
  public var inputPorts: [PolicyGraphPortId]
  public var outputPorts: [PolicyGraphPortId]
  public var groupId: PolicyGraphGroupId?
  public var position: PolicyCanvasPoint

  public var title: String {
    get { label }
    set { label = newValue }
  }

  public var inputs: [PolicyPipelinePort] {
    inputPorts.map { PolicyPipelinePort(id: $0, title: $0.rawValue) }
  }

  public var outputs: [PolicyPipelinePort] {
    outputPorts.map { PolicyPipelinePort(id: $0, title: $0.rawValue) }
  }

  public init(
    id: PolicyGraphNodeId,
    title: String,
    kind: PolicyGraphNodeKind,
    automation: PolicyGraphAutomationBinding? = nil,
    position: PolicyCanvasPoint = .zero,
    groupId: PolicyGraphGroupId? = nil,
    inputs: [PolicyPipelinePort] = [],
    outputs: [PolicyPipelinePort] = []
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
    id: PolicyGraphNodeId,
    label: String,
    kind: PolicyGraphNodeKind,
    automation: PolicyGraphAutomationBinding? = nil,
    inputPorts: [PolicyGraphPortId] = [],
    outputPorts: [PolicyGraphPortId] = [],
    groupId: PolicyGraphGroupId? = nil
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
    id = try container.decode(PolicyGraphNodeId.self, forKey: .id)
    label = try container.decode(String.self, forKey: .label)
    kind = try container.decode(PolicyGraphNodeKind.self, forKey: .kind)
    automation = try container.decodeIfPresent(
      PolicyGraphAutomationBinding.self,
      forKey: .automation
    )
    inputPorts = try container.decodeIfPresent([PolicyGraphPortId].self, forKey: .inputPorts) ?? []
    outputPorts =
      try container.decodeIfPresent([PolicyGraphPortId].self, forKey: .outputPorts) ?? []
    groupId = try container.decodeIfPresent(PolicyGraphGroupId.self, forKey: .groupId)
    position = .zero
  }
}
