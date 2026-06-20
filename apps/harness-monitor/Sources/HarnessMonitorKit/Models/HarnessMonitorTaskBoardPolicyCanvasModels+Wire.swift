import Foundation

// Map the generated task-board policy-canvas wire types to the rich app models.
// The wire types own the daemon snake_case decode through the plain decoder; the
// hand models keep their app shape (Int counts, optional document, the renamed
// TaskBoardPolicyPipelineMode). `mode` shares its raw values with the wire
// PolicyGraphMode, and `document` already decodes through the plain-decoder-safe
// hand TaskBoardPolicyPipelineDocument, so it passes straight through.

extension TaskBoardPolicyCanvasSummary {
  public init(wire: TaskBoardPolicyCanvasSummaryWire) {
    self.init(
      canvasId: wire.canvasId,
      title: wire.title,
      revision: wire.revision,
      mode: TaskBoardPolicyPipelineMode(rawValue: wire.mode.rawValue) ?? .draft,
      document: wire.document,
      nodeCount: Int(wire.nodeCount),
      edgeCount: Int(wire.edgeCount),
      groupCount: Int(wire.groupCount),
      latestSimulationTraceId: wire.latestSimulationTraceId,
      latestSimulationSucceeded: wire.latestSimulationSucceeded,
      latestSimulationAt: wire.latestSimulationAt,
      updatedAt: wire.updatedAt
    )
  }
}

extension TaskBoardPolicyCanvasWorkspace {
  public init(wire: TaskBoardPolicyCanvasWorkspaceResponseWire) {
    self.init(
      schemaVersion: UInt64(wire.schemaVersion),
      activeCanvasId: wire.activeCanvasId,
      canvases: wire.canvases.map(TaskBoardPolicyCanvasSummary.init(wire:)),
      globalPolicyEnforcementEnabled: wire.globalPolicyEnforcementEnabled,
      scenarios: wire.scenarios
    )
  }
}

extension TaskBoardPolicyExportResponse {
  public init(wire: TaskBoardPolicyExportResponseWire) {
    self.init(
      canvasId: wire.canvasId,
      title: wire.title,
      document: wire.document
    )
  }
}
