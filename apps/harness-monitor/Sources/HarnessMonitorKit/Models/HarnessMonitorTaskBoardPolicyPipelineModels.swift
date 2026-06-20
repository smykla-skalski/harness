import Foundation

public struct TaskBoardPolicyCanvasSummary: Codable, Equatable, Identifiable, Sendable {
  public var canvasId: String
  public var title: String
  public var revision: UInt64
  public var mode: TaskBoardPolicyPipelineMode
  public var document: TaskBoardPolicyPipelineDocument?
  public var nodeCount: Int
  public var edgeCount: Int
  public var groupCount: Int
  public var latestSimulationTraceId: String?
  public var latestSimulationSucceeded: Bool?
  public var latestSimulationAt: String?
  public var updatedAt: String

  public var id: String { canvasId }

  public init(
    canvasId: String,
    title: String,
    revision: UInt64,
    mode: TaskBoardPolicyPipelineMode,
    document: TaskBoardPolicyPipelineDocument? = nil,
    nodeCount: Int,
    edgeCount: Int,
    groupCount: Int,
    latestSimulationTraceId: String? = nil,
    latestSimulationSucceeded: Bool? = nil,
    latestSimulationAt: String? = nil,
    updatedAt: String
  ) {
    self.canvasId = canvasId
    self.title = title
    self.revision = revision
    self.mode = mode
    self.document = document
    self.nodeCount = nodeCount
    self.edgeCount = edgeCount
    self.groupCount = groupCount
    self.latestSimulationTraceId = latestSimulationTraceId
    self.latestSimulationSucceeded = latestSimulationSucceeded
    self.latestSimulationAt = latestSimulationAt
    self.updatedAt = updatedAt
  }

  enum CodingKeys: String, CodingKey {
    case canvasId = "canvas_id"
    case title
    case revision
    case mode
    case document
    case nodeCount = "node_count"
    case edgeCount = "edge_count"
    case groupCount = "group_count"
    case latestSimulationTraceId = "latest_simulation_trace_id"
    case latestSimulationSucceeded = "latest_simulation_succeeded"
    case latestSimulationAt = "latest_simulation_at"
    case updatedAt = "updated_at"
  }
}

public struct TaskBoardPolicyCanvasWorkspace: Codable, Equatable, Sendable {
  public var schemaVersion: UInt64
  public var activeCanvasId: String
  public var canvases: [TaskBoardPolicyCanvasSummary]
  public var globalPolicyEnforcementEnabled: Bool
  public var scenarios: [PolicyScenario]

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case activeCanvasId = "active_canvas_id"
    case canvases
    case globalPolicyEnforcementEnabled = "global_policy_enforcement_enabled"
    case scenarios
  }

  public init(
    schemaVersion: UInt64,
    activeCanvasId: String,
    canvases: [TaskBoardPolicyCanvasSummary],
    globalPolicyEnforcementEnabled: Bool = true,
    scenarios: [PolicyScenario] = []
  ) {
    self.schemaVersion = schemaVersion
    self.activeCanvasId = activeCanvasId
    self.canvases = canvases
    self.globalPolicyEnforcementEnabled = globalPolicyEnforcementEnabled
    self.scenarios = scenarios
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.schemaVersion = try container.decode(UInt64.self, forKey: .schemaVersion)
    self.activeCanvasId = try container.decode(String.self, forKey: .activeCanvasId)
    self.canvases = try container.decode([TaskBoardPolicyCanvasSummary].self, forKey: .canvases)
    self.globalPolicyEnforcementEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .globalPolicyEnforcementEnabled)
      ?? true
    self.scenarios =
      try container.decodeIfPresent([PolicyScenario].self, forKey: .scenarios) ?? []
  }
}

public struct TaskBoardPolicyCanvasCreateRequest: Codable, Equatable, Sendable {
  public var title: String?

  public init(title: String? = nil) {
    self.title = title
  }
}

public struct TaskBoardPolicyCanvasDuplicateRequest: Codable, Equatable, Sendable {
  public var canvasId: String
  public var title: String?

  public init(canvasId: String, title: String? = nil) {
    self.canvasId = canvasId
    self.title = title
  }
}

public struct TaskBoardPolicyCanvasRenameRequest: Codable, Equatable, Sendable {
  public var canvasId: String
  public var title: String

  public init(canvasId: String, title: String) {
    self.canvasId = canvasId
    self.title = title
  }
}

public struct TaskBoardPolicyCanvasActivateRequest: Codable, Equatable, Sendable {
  public var canvasId: String

  public init(canvasId: String) { self.canvasId = canvasId }
}

public struct TaskBoardPolicyCanvasDeleteRequest: Codable, Equatable, Sendable {
  public var canvasId: String

  public init(canvasId: String) { self.canvasId = canvasId }
}

public struct TaskBoardPolicyCanvasSetGlobalEnforcementRequest: Codable, Equatable, Sendable {
  public var enabled: Bool

  public init(enabled: Bool) {
    self.enabled = enabled
  }
}

public struct TaskBoardPolicyScenarioCreateRequest: Codable, Equatable, Sendable {
  public var name: String
  public var input: PolicyInput

  public init(name: String, input: PolicyInput) {
    self.name = name
    self.input = input
  }
}

public struct TaskBoardPolicyScenarioUpdateRequest: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var input: PolicyInput

  public init(id: String, name: String, input: PolicyInput) {
    self.id = id
    self.name = name
    self.input = input
  }
}

public struct TaskBoardPolicyScenarioDeleteRequest: Codable, Equatable, Sendable {
  public var id: String

  public init(id: String) { self.id = id }
}

public struct TaskBoardPolicyScenarioResetRequest: Codable, Equatable, Sendable {
  public init() {}
}

public struct TaskBoardPolicyPipelineSaveDraftRequest: Codable, Equatable, Sendable {
  public var canvasId: String
  public var document: TaskBoardPolicyPipelineDocument
  public var ifRevision: UInt64
  public init(
    canvasId: String, document: TaskBoardPolicyPipelineDocument, ifRevision: UInt64? = nil
  ) {
    self.canvasId = canvasId
    self.document = document
    self.ifRevision = ifRevision ?? document.revision
  }
}

public struct TaskBoardPolicyPipelineSaveDraftResponse: Codable, Equatable, Sendable {
  public var document: TaskBoardPolicyPipelineDocument
  public var validation: TaskBoardPolicyPipelineValidation
  public init(
    document: TaskBoardPolicyPipelineDocument, validation: TaskBoardPolicyPipelineValidation
  ) {
    self.document = document
    self.validation = validation
  }
}

public struct TaskBoardPolicyPipelineSimulateRequest: Codable, Equatable, Sendable {
  public var canvasId: String?
  public var document: TaskBoardPolicyPipelineDocument?

  public init(canvasId: String? = nil, document: TaskBoardPolicyPipelineDocument? = nil) {
    self.canvasId = canvasId
    self.document = document
  }
}

public struct TaskBoardPolicyPipelinePromoteRequest: Codable, Equatable, Sendable {
  public var canvasId: String?
  public var revision: UInt64
  public var actor: String?

  public init(canvasId: String? = nil, revision: UInt64, actor: String? = nil) {
    self.canvasId = canvasId
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

  enum CodingKeys: String, CodingKey {
    case document
    case traceId = "trace_id"
  }
}

public struct TaskBoardPolicyPipelineMakeLiveRequest: Codable, Equatable, Sendable {
  public var canvasId: String?
  public var revision: UInt64
  public var actor: String?

  public init(canvasId: String? = nil, revision: UInt64, actor: String? = nil) {
    self.canvasId = canvasId
    self.revision = revision
    self.actor = actor
  }

  enum CodingKeys: String, CodingKey {
    case canvasId = "canvas_id"
    case revision
    case actor
  }
}

/// Hand-authored because the make-live response carries the post-promotion
/// workspace snapshot the generated `PolicyPipelineMakeLiveResponse` does not
/// model (and types `document` as the hand `TaskBoardPolicyPipelineDocument`,
/// not the bare generated `PolicyGraph`). The workspace lets the store run one
/// deterministic `syncTaskBoardPolicyCanvasWorkspace` instead of re-fetching.
public struct TaskBoardPolicyPipelineMakeLiveResponse: Codable, Equatable, Sendable {
  public var document: TaskBoardPolicyPipelineDocument
  public var traceId: String
  public var globalPolicyEnforcementEnabled: Bool
  public var workspace: TaskBoardPolicyCanvasWorkspace

  public init(
    document: TaskBoardPolicyPipelineDocument,
    traceId: String,
    globalPolicyEnforcementEnabled: Bool,
    workspace: TaskBoardPolicyCanvasWorkspace
  ) {
    self.document = document
    self.traceId = traceId
    self.globalPolicyEnforcementEnabled = globalPolicyEnforcementEnabled
    self.workspace = workspace
  }

  enum CodingKeys: String, CodingKey {
    case document
    case traceId = "trace_id"
    case globalPolicyEnforcementEnabled = "global_policy_enforcement_enabled"
    case workspace
  }
}

/// Candidate selector for the read-only go-live decision diff. `document` lets a
/// caller diff an unsaved draft; the go-live sheet sends only `canvasId` so the
/// preview matches the saved revision make-live will actually enforce.
public struct TaskBoardPolicyPipelineGoLiveDiffRequest: Codable, Equatable, Sendable {
  public var canvasId: String?
  public var document: TaskBoardPolicyPipelineDocument?

  public init(canvasId: String? = nil, document: TaskBoardPolicyPipelineDocument? = nil) {
    self.canvasId = canvasId
    self.document = document
  }

  enum CodingKeys: String, CodingKey {
    case canvasId = "canvas_id"
    case document
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

extension TaskBoardPolicyPipelineAuditSummary {
  /// Map the generated audit wire type to the rich app summary. `mode` shares its
  /// raw values with the wire `PolicyGraphMode`; the nested simulation and
  /// validation reuse their own wire mappings, which fix the dropped issue ids.
  public init(wire: PolicyPipelineAuditSummaryWire) {
    self.init(
      activeRevision: wire.activeRevision,
      mode: TaskBoardPolicyPipelineMode(rawValue: wire.mode.rawValue) ?? .draft,
      latestTraceId: wire.latestTraceId,
      latestSimulation: wire.latestSimulation.map(
        TaskBoardPolicyPipelineSimulationResult.init(wire:)),
      validation: TaskBoardPolicyPipelineValidation(wire: wire.validation)
    )
  }
}
