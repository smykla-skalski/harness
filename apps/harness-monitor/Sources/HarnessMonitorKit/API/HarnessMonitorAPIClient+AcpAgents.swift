import Foundation

extension HarnessMonitorAPIClient {
  public func startManagedAcpAgent(
    sessionID: String,
    request: AcpAgentStartRequest
  ) async throws -> ManagedAgentSnapshot {
    let wire: ManagedAgentSnapshotWire = try await post(
      "/v1/sessions/\(sessionID)/managed-agents/acp", body: request,
      decoder: PolicyWireCoding.decoder
    )
    return try ManagedAgentSnapshot(wire: wire)
  }

  public func resolveManagedAcpPermission(
    agentID: String,
    batchID: String,
    decision: AcpPermissionDecision
  ) async throws -> ManagedAgentSnapshot {
    let wire: ManagedAgentSnapshotWire = try await post(
      "/v1/managed-agents/\(agentID)/permission-batches/\(batchID)",
      body: AcpPermissionDecisionWire(decision),
      decoder: PolicyWireCoding.decoder
    )
    return try ManagedAgentSnapshot(wire: wire)
  }

  public func stopManagedAcpAgent(agentID: String) async throws -> ManagedAgentSnapshot {
    let wire: ManagedAgentSnapshotWire = try await delete(
      "/v1/managed-agents/\(agentID)", decoder: PolicyWireCoding.decoder
    )
    return try ManagedAgentSnapshot(wire: wire)
  }

  public func promptManagedAcpAgent(
    agentID: String,
    prompt: String
  ) async throws -> ManagedAgentSnapshot {
    struct Body: Encodable { let prompt: String }
    let wire: ManagedAgentSnapshotWire = try await post(
      "/v1/managed-agents/\(agentID)/prompt",
      body: Body(prompt: prompt),
      decoder: PolicyWireCoding.decoder
    )
    return try ManagedAgentSnapshot(wire: wire)
  }

  public func openRouterModelCatalog() async throws -> OpenRouterModelCatalogResponse {
    try await get("/v1/openrouter/models", decoder: PolicyWireCoding.decoder)
  }
}
