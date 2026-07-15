import Foundation

// Map the generated policy-canvas wire types to the rich app models.
// The wire types own the daemon snake_case decode through the plain decoder; the
// hand models keep their app shape (Int counts, optional document, the renamed
// PolicyPipelineMode). `mode` shares its raw values with the wire
// PolicyGraphMode, and `document` already decodes through the plain-decoder-safe
// hand PolicyPipelineDocument, so it passes straight through.

extension PolicyCanvasSummary {
  public init(wire: PolicyCanvasSummaryWire) {
    self.init(
      canvasId: wire.canvasId,
      title: wire.title,
      revision: wire.revision,
      mode: PolicyPipelineMode(rawValue: wire.mode.rawValue) ?? .draft,
      document: wire.document,
      liveDocument: wire.liveDocument,
      liveUpdatedAt: wire.liveUpdatedAt,
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

extension PolicyCanvasWorkspace {
  public init(wire: PolicyCanvasWorkspaceResponseWire) {
    self.init(
      schemaVersion: UInt64(wire.schemaVersion),
      activeCanvasId: wire.activeCanvasId,
      canvases: wire.canvases.map(PolicyCanvasSummary.init(wire:)),
      globalPolicyEnforcementEnabled: wire.globalPolicyEnforcementEnabled,
      spawnRequiresLivePolicy: wire.spawnRequiresLivePolicy,
      spawnKillSwitch: wire.spawnKillSwitch,
      scenarios: wire.scenarios
    )
  }
}

extension PolicyCanvasExportResponse {
  public init(wire: PolicyCanvasExportResponseWire) {
    self.init(
      canvasId: wire.canvasId,
      title: wire.title,
      document: wire.document
    )
  }
}
