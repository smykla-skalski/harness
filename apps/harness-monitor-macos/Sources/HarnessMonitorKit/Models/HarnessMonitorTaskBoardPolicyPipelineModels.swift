import Foundation

public struct TaskBoardPolicyPipelineValidation: Codable, Equatable, Sendable {
  public var isValid: Bool
  public var issues: [TaskBoardPolicyPipelineValidationIssue]

  public init(isValid: Bool, issues: [TaskBoardPolicyPipelineValidationIssue] = []) {
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
      try container.decodeIfPresent([TaskBoardPolicyPipelineValidationIssue].self, forKey: .issues)
      ?? []
    isValid = try container.decodeIfPresent(Bool.self, forKey: .isValid) ?? issues.isEmpty
  }
}

public struct TaskBoardPolicyPipelineValidationIssue: Codable, Equatable, Sendable {
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
  public var action: TaskBoardPolicyAction?
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
    action: TaskBoardPolicyAction? = nil,
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
    case nodeId
    case edgeId
    case nodeIds
    case expected
    case actual
    case port
    case direction
    case action
    case location

    init?(stringValue: String) {
      switch stringValue {
      case "issue":
        self = .issue
      case "code":
        self = .code
      case "message":
        self = .message
      case "id":
        self = .id
      case "node_id", "nodeId":
        self = .nodeId
      case "edge_id", "edgeId":
        self = .edgeId
      case "node_ids", "nodeIds":
        self = .nodeIds
      case "expected":
        self = .expected
      case "actual":
        self = .actual
      case "port":
        self = .port
      case "direction":
        self = .direction
      case "action":
        self = .action
      case "location":
        self = .location
      default:
        return nil
      }
    }

    var stringValue: String {
      switch self {
      case .issue:
        "issue"
      case .code:
        "code"
      case .message:
        "message"
      case .id:
        "id"
      case .nodeId:
        "node_id"
      case .edgeId:
        "edge_id"
      case .nodeIds:
        "node_ids"
      case .expected:
        "expected"
      case .actual:
        "actual"
      case .port:
        "port"
      case .direction:
        "direction"
      case .action:
        "action"
      case .location:
        "location"
      }
    }

    init?(intValue: Int) {
      return nil
    }

    var intValue: Int? {
      nil
    }
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
    action = try container.decodeIfPresent(TaskBoardPolicyAction.self, forKey: .action)
    location = try container.decodeIfPresent(String.self, forKey: .location)
    message =
      try container.decodeIfPresent(String.self, forKey: .message)
      ?? Self.defaultMessage(
        code: code,
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

  private static func defaultMessage(
    code: String,
    id: String?,
    nodeId: String?,
    edgeId: String?,
    nodeIds: [String],
    expected: UInt16?,
    actual: UInt16?,
    port: String?,
    direction: String?,
    action: TaskBoardPolicyAction?,
    location: String?
  ) -> String {
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

public struct TaskBoardPolicyPipelineSimulatedDecision: Codable, Equatable, Sendable {
  public var action: TaskBoardPolicyAction
  public var decision: TaskBoardPolicyDecision
  public var visitedNodeIds: [String]
  public var policyTraceIds: [String]

  public init(
    action: TaskBoardPolicyAction,
    decision: TaskBoardPolicyDecision,
    visitedNodeIds: [String] = [],
    policyTraceIds: [String] = []
  ) {
    self.action = action
    self.decision = decision
    self.visitedNodeIds = visitedNodeIds
    self.policyTraceIds = policyTraceIds
  }
}

public struct TaskBoardPolicyPipelineSimulationResult: Codable, Equatable, Sendable {
  public var revision: UInt64
  public var traceId: String
  public var simulatedAt: String
  public var succeeded: Bool
  public var validation: TaskBoardPolicyPipelineValidation
  public var decisions: [TaskBoardPolicyPipelineSimulatedDecision]
  public var policyTraceIds: [String]

  public init(
    revision: UInt64,
    traceId: String,
    simulatedAt: String,
    succeeded: Bool,
    validation: TaskBoardPolicyPipelineValidation,
    decisions: [TaskBoardPolicyPipelineSimulatedDecision] = [],
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

public struct TaskBoardPolicyPipelineSaveDraftRequest: Codable, Equatable, Sendable {
  public var document: TaskBoardPolicyPipelineDocument

  public init(document: TaskBoardPolicyPipelineDocument) {
    self.document = document
  }
}

public struct TaskBoardPolicyPipelineSaveDraftResponse: Codable, Equatable, Sendable {
  public var document: TaskBoardPolicyPipelineDocument
  public var validation: TaskBoardPolicyPipelineValidation

  public init(
    document: TaskBoardPolicyPipelineDocument,
    validation: TaskBoardPolicyPipelineValidation
  ) {
    self.document = document
    self.validation = validation
  }
}

public struct TaskBoardPolicyPipelineSimulateRequest: Codable, Equatable, Sendable {
  public var document: TaskBoardPolicyPipelineDocument?

  public init(document: TaskBoardPolicyPipelineDocument? = nil) {
    self.document = document
  }
}

public struct TaskBoardPolicyPipelinePromoteRequest: Codable, Equatable, Sendable {
  public var revision: UInt64
  public var actor: String?

  public init(revision: UInt64, actor: String? = nil) {
    self.revision = revision
    self.actor = actor
  }
}

public struct TaskBoardPolicyPipelinePromoteResponse: Codable, Equatable, Sendable {
  public var document: TaskBoardPolicyPipelineDocument
  public var traceId: String

  public init(document: TaskBoardPolicyPipelineDocument, traceId: String) {
    self.document = document
    self.traceId = traceId
  }
}

public struct TaskBoardPolicyPipelineAuditSummary: Codable, Equatable, Sendable {
  public var activeRevision: UInt64
  public var mode: TaskBoardPolicyPipelineMode
  public var latestTraceId: String?
  public var latestSimulation: TaskBoardPolicyPipelineSimulationResult?
  public var validation: TaskBoardPolicyPipelineValidation

  public init(
    activeRevision: UInt64,
    mode: TaskBoardPolicyPipelineMode,
    latestTraceId: String? = nil,
    latestSimulation: TaskBoardPolicyPipelineSimulationResult? = nil,
    validation: TaskBoardPolicyPipelineValidation
  ) {
    self.activeRevision = activeRevision
    self.mode = mode
    self.latestTraceId = latestTraceId
    self.latestSimulation = latestSimulation
    self.validation = validation
  }
}
