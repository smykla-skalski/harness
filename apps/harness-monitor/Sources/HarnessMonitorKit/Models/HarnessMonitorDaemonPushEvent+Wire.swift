import Foundation

// Wire maps for the ACP incident + agents-reconciled push payloads. The two incident payloads are
// flat scalar mirrors; the reconciled payload reuses the agent-snapshot map (which rethrows on a
// malformed managed-agent pair) and the inspect-response map.

extension AcpProcessIncidentPayload {
  init(wire: AcpProcessIncidentPayloadWire) {
    self.init(
      kind: wire.kind,
      reasonKind: wire.reasonKind,
      processKey: wire.processKey,
      pid: wire.pid,
      pgid: wire.pgid,
      exitCode: wire.exitCode,
      exitSignal: wire.exitSignal,
      stderrTail: wire.stderrTail,
      affectedLogicalSessionIds: wire.affectedLogicalSessionIds
    )
  }
}

extension AcpBridgeResyncIncidentPayload {
  init(wire: AcpBridgeResyncIncidentPayloadWire) {
    self.init(
      kind: wire.kind,
      bridgeEpoch: wire.bridgeEpoch,
      continuity: wire.continuity,
      nextSeq: wire.nextSeq,
      truncated: wire.truncated,
      affectedLogicalSessionIds: wire.affectedLogicalSessionIds
    )
  }
}

extension AcpAgentsReconciledPayload {
  init(wire: AcpAgentsReconciledPayloadWire) throws {
    self.init(
      sessionId: wire.sessionId,
      agents: try wire.agents.map(AcpAgentSnapshot.init(wire:)),
      inspect: wire.inspect.map(AcpAgentInspectResponse.init(wire:))
    )
  }
}
