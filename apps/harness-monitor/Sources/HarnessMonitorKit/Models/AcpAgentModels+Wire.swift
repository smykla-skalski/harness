import Foundation

// Map the generated acp permission wire types to the hand models. The batch wire comes from
// the owned AcpPermissionBatchDecode (the public type has no serde derive); its
// managed_agent_id maps to the hand acpId and the dropped managed_agent_family is implied acp.
// The item models tool_call and the external-crate permission options as raw JSONValue. These
// feed AcpAgentSnapshot.pendingPermissionBatches.

extension AcpPermissionItem {
  public init(wire: AcpPermissionItemWire) {
    self.init(
      requestId: wire.requestId,
      sessionId: wire.sessionId,
      toolCall: wire.toolCall,
      options: wire.options
    )
  }
}

extension AcpPermissionBatch {
  public init(wire: AcpPermissionBatchWire) {
    self.init(
      batchId: wire.batchId,
      acpId: wire.managedAgentId,
      sessionId: wire.sessionId,
      requests: wire.requests.map(AcpPermissionItem.init(wire:)),
      createdAt: wire.createdAt,
      expiresAt: wire.expiresAt
    )
  }
}
