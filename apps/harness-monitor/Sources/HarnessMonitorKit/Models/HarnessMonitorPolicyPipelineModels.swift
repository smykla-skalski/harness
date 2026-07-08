import Foundation

public struct PolicyCanvasSummary: Codable, Equatable, Identifiable, Sendable {
  public var canvasId: String
  public var title: String
  public var revision: UInt64
  public var mode: PolicyPipelineMode
  public var document: PolicyPipelineDocument?
  public var liveDocument: PolicyPipelineDocument?
  public var liveUpdatedAt: String?
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
    mode: PolicyPipelineMode,
    document: PolicyPipelineDocument? = nil,
    liveDocument: PolicyPipelineDocument? = nil,
    liveUpdatedAt: String? = nil,
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
    self.liveDocument = liveDocument
    self.liveUpdatedAt = liveUpdatedAt
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
    case liveDocument = "live_document"
    case liveUpdatedAt = "live_updated_at"
    case nodeCount = "node_count"
    case edgeCount = "edge_count"
    case groupCount = "group_count"
    case latestSimulationTraceId = "latest_simulation_trace_id"
    case latestSimulationSucceeded = "latest_simulation_succeeded"
    case latestSimulationAt = "latest_simulation_at"
    case updatedAt = "updated_at"
  }
}

public struct PolicyCanvasWorkspace: Codable, Equatable, Sendable {
  public var schemaVersion: UInt64
  public var activeCanvasId: String
  public var canvases: [PolicyCanvasSummary]
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
    canvases: [PolicyCanvasSummary],
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
    self.canvases = try container.decode([PolicyCanvasSummary].self, forKey: .canvases)
    self.globalPolicyEnforcementEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .globalPolicyEnforcementEnabled)
      ?? true
    self.scenarios =
      try container.decodeIfPresent([PolicyScenario].self, forKey: .scenarios) ?? []
  }
}

public struct PolicyCanvasCreateRequest: Codable, Equatable, Sendable {
  public var title: String?

  public init(title: String? = nil) {
    self.title = title
  }
}

public struct PolicyCanvasDuplicateRequest: Codable, Equatable, Sendable {
  public var canvasId: String
  public var title: String?

  public init(canvasId: String, title: String? = nil) {
    self.canvasId = canvasId
    self.title = title
  }
}

public struct PolicyCanvasRenameRequest: Codable, Equatable, Sendable {
  public var canvasId: String
  public var title: String

  public init(canvasId: String, title: String) {
    self.canvasId = canvasId
    self.title = title
  }
}

public struct PolicyCanvasActivateRequest: Codable, Equatable, Sendable {
  public var canvasId: String

  public init(canvasId: String) { self.canvasId = canvasId }
}

public struct PolicyCanvasDeleteRequest: Codable, Equatable, Sendable {
  public var canvasId: String

  public init(canvasId: String) { self.canvasId = canvasId }
}

public struct PolicyCanvasSetGlobalEnforcementRequest: Codable, Equatable, Sendable {
  public var enabled: Bool

  public init(enabled: Bool) {
    self.enabled = enabled
  }
}

public struct PolicyScenarioCreateRequest: Codable, Equatable, Sendable {
  public var name: String
  public var input: PolicyInput

  public init(name: String, input: PolicyInput) {
    self.name = name
    self.input = input
  }
}

public struct PolicyScenarioUpdateRequest: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var input: PolicyInput

  public init(id: String, name: String, input: PolicyInput) {
    self.id = id
    self.name = name
    self.input = input
  }
}

public struct PolicyScenarioDeleteRequest: Codable, Equatable, Sendable {
  public var id: String

  public init(id: String) { self.id = id }
}

public struct PolicyScenarioResetRequest: Codable, Equatable, Sendable {
  public init() {}
}

public struct PolicyPipelineSaveDraftRequest: Codable, Equatable, Sendable {
  public var canvasId: String
  public var document: PolicyPipelineDocument
  public var ifRevision: UInt64
  public init(
    canvasId: String, document: PolicyPipelineDocument, ifRevision: UInt64? = nil
  ) {
    self.canvasId = canvasId
    self.document = document
    self.ifRevision = ifRevision ?? document.revision
  }
}

public struct PolicyPipelineSaveDraftResponse: Codable, Equatable, Sendable {
  public var document: PolicyPipelineDocument
  public var validation: PolicyPipelineValidation
  public init(
    document: PolicyPipelineDocument, validation: PolicyPipelineValidation
  ) {
    self.document = document
    self.validation = validation
  }
}

public struct PolicyPipelineSimulateRequest: Codable, Equatable, Sendable {
  public var canvasId: String?
  public var document: PolicyPipelineDocument?

  public init(canvasId: String? = nil, document: PolicyPipelineDocument? = nil) {
    self.canvasId = canvasId
    self.document = document
  }
}

public struct PolicyPipelineReplayRequest: Codable, Equatable, Sendable {
  public var canvasId: String?
  public var limit: UInt32?

  public init(canvasId: String? = nil, limit: UInt32? = nil) {
    self.canvasId = canvasId
    self.limit = limit
  }
}

public struct PolicyPipelinePromoteRequest: Codable, Equatable, Sendable {
  public var canvasId: String?
  public var revision: UInt64
  public var actor: String?

  public init(canvasId: String? = nil, revision: UInt64, actor: String? = nil) {
    self.canvasId = canvasId
    self.revision = revision
    self.actor = actor
  }
}

public struct PolicyPipelinePromoteResponse: Codable, Equatable, Sendable {
  public var document: PolicyPipelineDocument
  public var traceId: String

  public init(document: PolicyPipelineDocument, traceId: String) {
    self.document = document
    self.traceId = traceId
  }

  enum CodingKeys: String, CodingKey {
    case document
    case traceId = "trace_id"
  }
}

public struct PolicyPipelineMakeLiveRequest: Codable, Equatable, Sendable {
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
/// model (and types `document` as the hand `PolicyPipelineDocument`,
/// not the bare generated `PolicyGraph`). The workspace lets the store run one
/// deterministic `syncPolicyCanvasWorkspace` instead of re-fetching.
public struct PolicyPipelineMakeLiveResponse: Codable, Equatable, Sendable {
  public var document: PolicyPipelineDocument
  public var traceId: String
  public var globalPolicyEnforcementEnabled: Bool
  public var workspace: PolicyCanvasWorkspace

  public init(
    document: PolicyPipelineDocument,
    traceId: String,
    globalPolicyEnforcementEnabled: Bool,
    workspace: PolicyCanvasWorkspace
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
public struct PolicyPipelineGoLiveDiffRequest: Codable, Equatable, Sendable {
  public var canvasId: String?
  public var document: PolicyPipelineDocument?

  public init(canvasId: String? = nil, document: PolicyPipelineDocument? = nil) {
    self.canvasId = canvasId
    self.document = document
  }

  enum CodingKeys: String, CodingKey {
    case canvasId = "canvas_id"
    case document
  }
}

public struct PolicyPipelineAuditSummary: Codable, Equatable, Sendable {
  public var activeRevision: UInt64
  public var mode: PolicyPipelineMode
  public var globalPolicyEnforcementEnabled: Bool
  public var latestTraceId: String?
  public var latestSimulation: PolicyPipelineSimulationResult?
  public var validation: PolicyPipelineValidation

  public init(
    activeRevision: UInt64,
    mode: PolicyPipelineMode,
    globalPolicyEnforcementEnabled: Bool = true,
    latestTraceId: String? = nil,
    latestSimulation: PolicyPipelineSimulationResult? = nil,
    validation: PolicyPipelineValidation
  ) {
    self.activeRevision = activeRevision
    self.mode = mode
    self.globalPolicyEnforcementEnabled = globalPolicyEnforcementEnabled
    self.latestTraceId = latestTraceId
    self.latestSimulation = latestSimulation
    self.validation = validation
  }

  private enum CodingKeys: String, CodingKey {
    case activeRevision = "active_revision"
    case mode
    case globalPolicyEnforcementEnabled = "global_policy_enforcement_enabled"
    case latestTraceId = "latest_trace_id"
    case latestSimulation = "latest_simulation"
    case validation
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    activeRevision = try container.decode(UInt64.self, forKey: .activeRevision)
    mode = try container.decode(PolicyPipelineMode.self, forKey: .mode)
    globalPolicyEnforcementEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .globalPolicyEnforcementEnabled) ?? true
    latestTraceId = try container.decodeIfPresent(String.self, forKey: .latestTraceId)
    latestSimulation = try container.decodeIfPresent(
      PolicyPipelineSimulationResult.self,
      forKey: .latestSimulation
    )
    validation = try container.decode(PolicyPipelineValidation.self, forKey: .validation)
  }
}

extension PolicyPipelineAuditSummary {
  /// Map the generated audit wire type to the rich app summary. `mode` shares its
  /// raw values with the wire `PolicyGraphMode`; the nested simulation and
  /// validation reuse their own wire mappings, which fix the dropped issue ids.
  public init(wire: PolicyPipelineAuditSummaryWire) {
    self.init(
      activeRevision: wire.activeRevision,
      mode: PolicyPipelineMode(rawValue: wire.mode.rawValue) ?? .draft,
      globalPolicyEnforcementEnabled: wire.globalPolicyEnforcementEnabled,
      latestTraceId: wire.latestTraceId,
      latestSimulation: wire.latestSimulation.map(
        PolicyPipelineSimulationResult.init(wire:)),
      validation: PolicyPipelineValidation(wire: wire.validation)
    )
  }
}
