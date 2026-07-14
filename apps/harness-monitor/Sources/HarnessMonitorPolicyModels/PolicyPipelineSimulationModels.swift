import Foundation

public struct PolicyPipelineValidation: Codable, Equatable, Sendable {
  public var isValid: Bool
  public var issues: [PolicyPipelineValidationIssue]

  public init(isValid: Bool, issues: [PolicyPipelineValidationIssue] = []) {
    self.isValid = isValid
    self.issues = issues
  }

  enum CodingKeys: String, CodingKey {
    case issues
    case isValid
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    issues =
      try container.decodeIfPresent([PolicyPipelineValidationIssue].self, forKey: .issues)
      ?? []
    isValid = try container.decodeIfPresent(Bool.self, forKey: .isValid) ?? issues.isEmpty
  }
}

public struct PolicyPipelineValidationIssue: Codable, Equatable, Sendable {
  public var code: String
  public var message: String
  public var id: String?
  public var nodeId: String?
  public var edgeId: String?
  public var nodeIds: [String]
  public var expected: UInt16?
  public var actual: UInt16?
  public var port: String?
  public var direction: String?
  public var action: PolicyAction?
  public var location: String?

  public init(
    code: String,
    message: String,
    id: String? = nil,
    nodeId: String? = nil,
    edgeId: String? = nil,
    nodeIds: [String] = [],
    expected: UInt16? = nil,
    actual: UInt16? = nil,
    port: String? = nil,
    direction: String? = nil,
    action: PolicyAction? = nil,
    location: String? = nil
  ) {
    self.code = code
    self.message = message
    self.id = id
    self.nodeId = nodeId
    self.edgeId = edgeId
    self.nodeIds = nodeIds
    self.expected = expected
    self.actual = actual
    self.port = port
    self.direction = direction
    self.action = action
    self.location = location
  }

  enum CodingKeys: String, CodingKey {
    case issue
    case code
    case message
    case id
    case nodeId = "node_id"
    case edgeId = "edge_id"
    case nodeIds = "node_ids"
    case expected
    case actual
    case port
    case direction
    case action
    case location
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    code =
      try container.decodeIfPresent(String.self, forKey: .issue)
      ?? container.decodeIfPresent(String.self, forKey: .code)
      ?? "unknown"
    id = try container.decodeIfPresent(String.self, forKey: .id)
    nodeId = try container.decodeIfPresent(String.self, forKey: .nodeId)
    edgeId = try container.decodeIfPresent(String.self, forKey: .edgeId)
    nodeIds = try container.decodeIfPresent([String].self, forKey: .nodeIds) ?? []
    expected = try container.decodeIfPresent(UInt16.self, forKey: .expected)
    actual = try container.decodeIfPresent(UInt16.self, forKey: .actual)
    port = try container.decodeIfPresent(String.self, forKey: .port)
    direction = try container.decodeIfPresent(String.self, forKey: .direction)
    action = try container.decodeIfPresent(PolicyAction.self, forKey: .action)
    location = try container.decodeIfPresent(String.self, forKey: .location)
    message = try container.decodeIfPresent(String.self, forKey: .message) ?? code
    if message == code {
      message = synthesizedMessage
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(code, forKey: .issue)
    if message != code {
      try container.encode(message, forKey: .message)
    }
    try container.encodeIfPresent(id, forKey: .id)
    try container.encodeIfPresent(nodeId, forKey: .nodeId)
    try container.encodeIfPresent(edgeId, forKey: .edgeId)
    if !nodeIds.isEmpty {
      try container.encode(nodeIds, forKey: .nodeIds)
    }
    try container.encodeIfPresent(expected, forKey: .expected)
    try container.encodeIfPresent(actual, forKey: .actual)
    try container.encodeIfPresent(port, forKey: .port)
    try container.encodeIfPresent(direction, forKey: .direction)
    try container.encodeIfPresent(action, forKey: .action)
    try container.encodeIfPresent(location, forKey: .location)
  }

  private var synthesizedMessage: String {
    switch code {
    case "unsupported_schema_version":
      let expectedText = expected.map(String.init) ?? "current"
      let actualText = actual.map(String.init) ?? "unknown"
      return "Unsupported schema version \(actualText); expected \(expectedText)"
    case "duplicate_id":
      return "Duplicate id \(id ?? "unknown") in \(location ?? "graph")"
    case "dangling_edge":
      return "Dangling edge \(edgeId ?? "unknown") references node \(nodeId ?? "unknown")"
    case "invalid_port":
      let directionText = direction ?? "port"
      return
        "Invalid \(directionText) port \(port ?? "unknown") on node \(nodeId ?? "unknown")"
    case "cycle":
      return "Cycle detected across \(nodeIds.joined(separator: ", "))"
    case "unsafe_high_risk_action":
      return "Unsafe high-risk action \(action?.rawValue ?? "unknown")"
    default:
      return code
    }
  }
}

public struct PolicySimulationDecision: Codable, Equatable, Sendable {
  public let decision: String
  public let reasonCode: String
  public let policyVersion: String

  public init(
    decision: String,
    reasonCode: String,
    policyVersion: String
  ) {
    self.decision = decision
    self.reasonCode = reasonCode
    self.policyVersion = policyVersion
  }
}

public struct PolicyPipelineSimulatedDecision: Codable, Equatable, Sendable {
  public var scenarioId: String
  public var scenarioName: String
  public var action: PolicyAction
  public var decision: PolicySimulationDecision
  public var visitedNodeIds: [String]
  public var policyTraceIds: [String]

  public init(
    scenarioId: String = "",
    scenarioName: String = "",
    action: PolicyAction,
    decision: PolicySimulationDecision,
    visitedNodeIds: [String] = [],
    policyTraceIds: [String] = []
  ) {
    self.scenarioId = scenarioId
    self.scenarioName = scenarioName
    self.action = action
    self.decision = decision
    self.visitedNodeIds = visitedNodeIds
    self.policyTraceIds = policyTraceIds
  }

  enum CodingKeys: String, CodingKey {
    case scenarioId
    case scenarioName
    case action
    case decision
    case visitedNodeIds
    case policyTraceIds
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    scenarioId = try container.decodeIfPresent(String.self, forKey: .scenarioId) ?? ""
    scenarioName = try container.decodeIfPresent(String.self, forKey: .scenarioName) ?? ""
    action = try container.decode(PolicyAction.self, forKey: .action)
    decision = try container.decode(PolicySimulationDecision.self, forKey: .decision)
    visitedNodeIds = try container.decodeIfPresent([String].self, forKey: .visitedNodeIds) ?? []
    policyTraceIds = try container.decodeIfPresent([String].self, forKey: .policyTraceIds) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(scenarioId, forKey: .scenarioId)
    try container.encode(scenarioName, forKey: .scenarioName)
    try container.encode(action, forKey: .action)
    try container.encode(decision, forKey: .decision)
    try container.encode(visitedNodeIds, forKey: .visitedNodeIds)
    try container.encode(policyTraceIds, forKey: .policyTraceIds)
  }
}

public struct PolicyPipelineSimulationResult: Codable, Equatable, Sendable {
  public var revision: UInt64
  public var traceId: String
  public var simulatedAt: String
  public var succeeded: Bool
  public var validation: PolicyPipelineValidation
  public var decisions: [PolicyPipelineSimulatedDecision]
  public var policyTraceIds: [String]

  public init(
    revision: UInt64,
    traceId: String,
    simulatedAt: String,
    succeeded: Bool,
    validation: PolicyPipelineValidation,
    decisions: [PolicyPipelineSimulatedDecision] = [],
    policyTraceIds: [String] = []
  ) {
    self.revision = revision
    self.traceId = traceId
    self.simulatedAt = simulatedAt
    self.succeeded = succeeded
    self.validation = validation
    self.decisions = decisions
    self.policyTraceIds = policyTraceIds
  }
}

// MARK: - Wire mapping

extension PolicySimulationDecision {
  /// Flatten the generated `PolicyDecision` tagged enum into the app's flat
  /// decision/reasonCode/policyVersion shape, keeping the daemon's snake_case
  /// discriminator the consumers already match on.
  public init(wire: PolicyDecision) {
    switch wire {
    case .allow(let reasonCode, let policyVersion):
      self.init(decision: "allow", reasonCode: reasonCode.rawValue, policyVersion: policyVersion)
    case .deny(let reasonCode, let policyVersion):
      self.init(decision: "deny", reasonCode: reasonCode.rawValue, policyVersion: policyVersion)
    case .requireHuman(let reasonCode, let policyVersion):
      self.init(
        decision: "require_human",
        reasonCode: reasonCode.rawValue,
        policyVersion: policyVersion
      )
    case .requireConsensus(let reasonCode, let policyVersion):
      self.init(
        decision: "require_consensus",
        reasonCode: reasonCode.rawValue,
        policyVersion: policyVersion
      )
    case .dryRunOnly(let reasonCode, let policyVersion):
      self.init(
        decision: "dry_run_only",
        reasonCode: reasonCode.rawValue,
        policyVersion: policyVersion
      )
    }
  }
}

extension PolicyPipelineValidationIssue {
  /// Flatten one generated `PolicyGraphValidationIssue` variant into the app's
  /// flat issue. Decoding through the generated enum (plain decoder) is what
  /// recovers node_id/edge_id/node_ids; the message the daemon never sends is
  /// resynthesized from the recovered fields.
  public init(wire: PolicyGraphValidationIssue) {
    var id: String?
    var nodeId: String?
    var edgeId: String?
    var nodeIds: [String] = []
    var expected: UInt16?
    var actual: UInt16?
    var port: String?
    var direction: String?
    var action: PolicyAction?
    var location: String?
    let code: String

    switch wire {
    case .unsupportedSchemaVersion(let expectedVersion, let actualVersion):
      code = "unsupported_schema_version"
      expected = expectedVersion
      actual = actualVersion
    case .duplicateId(let duplicateId, let duplicateLocation):
      code = "duplicate_id"
      id = duplicateId
      location = duplicateLocation
    case .danglingEdge(let danglingEdgeId, let danglingNodeId):
      code = "dangling_edge"
      edgeId = danglingEdgeId
      nodeId = danglingNodeId
    case .invalidPort(let portEdgeId, let portNodeId, let portName, let portDirection):
      code = "invalid_port"
      edgeId = portEdgeId
      nodeId = portNodeId
      port = portName
      direction = portDirection.rawValue
    case .cycle(let cycleNodeIds):
      code = "cycle"
      nodeIds = cycleNodeIds
    case .unsafeHighRiskAction(let riskAction):
      code = "unsafe_high_risk_action"
      action = riskAction
    case .incompatiblePayloadEdge(let incompatibleEdgeId, _, _):
      code = "incompatible_payload_edge"
      edgeId = incompatibleEdgeId
    case .spawnRouteMissingTerminal(let missingTerminalNodeId):
      code = "spawn_route_missing_terminal"
      nodeId = missingTerminalNodeId
    }

    self.init(
      code: code,
      message: code,
      id: id,
      nodeId: nodeId,
      edgeId: edgeId,
      nodeIds: nodeIds,
      expected: expected,
      actual: actual,
      port: port,
      direction: direction,
      action: action,
      location: location
    )
    message = synthesizedMessage
  }
}

extension PolicyPipelineValidation {
  public init(wire: PolicyGraphValidationReport) {
    self.init(
      isValid: wire.issues.isEmpty,
      issues: wire.issues.map(PolicyPipelineValidationIssue.init(wire:))
    )
  }
}

extension PolicyPipelineSimulatedDecision {
  public init(wire: PolicyPipelineSimulatedDecisionWire) {
    self.init(
      scenarioId: wire.scenarioId,
      scenarioName: wire.scenarioName,
      action: wire.action,
      decision: PolicySimulationDecision(wire: wire.decision),
      visitedNodeIds: wire.visitedNodeIds,
      policyTraceIds: wire.policyTraceIds
    )
  }
}

extension PolicyPipelineSimulationResult {
  public init(wire: PolicyPipelineSimulationResultWire) {
    self.init(
      revision: wire.revision,
      traceId: wire.traceId,
      simulatedAt: wire.simulatedAt,
      succeeded: wire.succeeded,
      validation: PolicyPipelineValidation(wire: wire.validation),
      decisions: wire.decisions.map(PolicyPipelineSimulatedDecision.init(wire:)),
      policyTraceIds: wire.policyTraceIds
    )
  }
}
