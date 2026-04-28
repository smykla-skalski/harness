import Foundation

extension HarnessMonitorAPIClient {
  public func startManagedAcpAgent(
    sessionID: String,
    request: AcpAgentStartRequest
  ) async throws -> ManagedAgentSnapshot {
    try await post("/v1/sessions/\(sessionID)/managed-agents/acp", body: request)
  }

  public func resolveManagedAcpPermission(
    agentID: String,
    batchID: String,
    decision: AcpPermissionDecision
  ) async throws -> ManagedAgentSnapshot {
    try await post(
      "/v1/managed-agents/\(agentID)/permission-batches/\(batchID)",
      body: decision
    )
  }

  public func stopManagedAcpAgent(agentID: String) async throws -> ManagedAgentSnapshot {
    try await delete("/v1/managed-agents/\(agentID)")
  }
}
