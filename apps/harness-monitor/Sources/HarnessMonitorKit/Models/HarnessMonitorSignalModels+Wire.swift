import Foundation

// Wire/model split for the session signal cluster (SessionDetail.signals). The generated *Wire
// types pin the daemon's snake_case keys for the plain PolicyWireCoding.decoder; these maps fold
// each wire onto its rich hand model (Identifiable, computed effectiveStatus). SignalPriority,
// AckResult and SessionSignalStatus are referenced bare by the wires - their single-word raw
// values decode identically under any key strategy, and SessionSignalStatus keeps its
// `acknowledged` legacy-alias decode, so the bare reference preserves it for free.

extension DeliveryConfig {
  init(wire: DeliveryConfigWire) {
    self.init(
      maxRetries: Int(wire.maxRetries),
      retryCount: Int(wire.retryCount),
      idempotencyKey: wire.idempotencyKey
    )
  }
}

extension SignalPayload {
  init(wire: SignalPayloadWire) {
    // The hand model defaults an absent metadata to an empty object; the wire defaults to .null
    // (the daemon skips a null metadata, so .null only ever means absent). Normalize to match.
    self.init(
      message: wire.message,
      actionHint: wire.actionHint,
      relatedFiles: wire.relatedFiles,
      metadata: wire.metadata == .null ? .object([:]) : wire.metadata
    )
  }
}

extension Signal {
  init(wire: SignalWire) {
    self.init(
      signalId: wire.signalId,
      version: Int(wire.version),
      createdAt: wire.createdAt,
      expiresAt: wire.expiresAt,
      sourceAgent: wire.sourceAgent,
      command: wire.command,
      priority: wire.priority,
      payload: SignalPayload(wire: wire.payload),
      delivery: DeliveryConfig(wire: wire.delivery)
    )
  }
}

extension SignalAck {
  init(wire: SignalAckWire) {
    self.init(
      signalId: wire.signalId,
      acknowledgedAt: wire.acknowledgedAt,
      result: wire.result,
      agent: wire.agent,
      sessionId: wire.sessionId,
      details: wire.details
    )
  }
}

extension SessionSignalRecord {
  init(wire: SessionSignalRecordWire) {
    self.init(
      runtime: wire.runtime,
      agentId: wire.agentId,
      sessionId: wire.sessionId,
      status: wire.status,
      signal: Signal(wire: wire.signal),
      acknowledgment: wire.acknowledgment.map(SignalAck.init(wire:))
    )
  }
}
