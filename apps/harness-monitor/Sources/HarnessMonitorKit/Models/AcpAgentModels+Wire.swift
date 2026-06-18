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

// The status object the daemon nests carries both the flattened AgentStatus and, for the
// disconnected variant, the reason/stderr_tail the hand snapshot exposes separately. Both
// AgentStatus and this details struct decode through the plain decoder (literal/explicit keys).
private struct AcpAgentStatusDetailsWire: Decodable {
  let reason: AgentDisconnectReason?
  let stderrTail: String?

  enum CodingKeys: String, CodingKey {
    case reason
    case stderrTail = "stderr_tail"
  }
}

extension AcpAgentSnapshot {
  public init(wire: AcpAgentSnapshotWire) throws {
    // status is a JSONValue passthrough (the Rust AgentStatus has a hand hybrid serde). Recover
    // the flattened status and, when disconnected, the reason/stderr_tail from the same payload.
    let statusData = try JSONEncoder().encode(wire.status)
    let status = try PolicyWireCoding.decoder.decode(AgentStatus.self, from: statusData)
    let details = try? PolicyWireCoding.decoder.decode(
      AcpAgentStatusDetailsWire.self, from: statusData
    )
    self.init(
      acpId: wire.managedAgentId,
      sessionId: wire.sessionId,
      agentId: wire.sessionAgentId,
      displayName: wire.displayName,
      status: status,
      pid: wire.pid,
      pgid: wire.pgid,
      projectDir: wire.projectDir,
      pendingPermissions: Int(wire.pendingPermissions),
      permissionQueueDepth: Int(wire.permissionQueueDepth),
      pendingPermissionBatches: wire.pendingPermissionBatches.map(AcpPermissionBatch.init(wire:)),
      terminalCount: Int(wire.terminalCount),
      createdAt: wire.createdAt,
      updatedAt: wire.updatedAt,
      disconnectReason: details?.reason,
      stderrTail: details?.stderrTail
    )
  }
}

extension AcpPermissionDecisionWire {
  init(_ decision: AcpPermissionDecision) {
    switch decision {
    case .approveAll: self = .approveAll
    case .approveSome(let requestIDs): self = .approveSome(requestIds: requestIDs)
    case .denyAll: self = .denyAll
    }
  }
}

extension AcpAgentStartRequestWire {
  init(_ request: AcpAgentStartRequest) {
    self.init(
      descriptorId: request.agent,
      role: request.role,
      fallbackRole: request.fallbackRole,
      capabilities: request.capabilities,
      name: request.name,
      prompt: request.prompt,
      projectDir: request.projectDir,
      persona: request.persona,
      taskId: request.taskID,
      boardItemId: request.boardItemID,
      workflowExecutionId: request.workflowExecutionID,
      model: request.model,
      effort: request.effort,
      allowCustomModel: request.allowCustomModel,
      recordPermissions: request.recordPermissions
    )
  }
}
