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

  public func promptManagedAcpAgent(
    agentID: String,
    prompt: String
  ) async throws -> ManagedAgentSnapshot {
    struct Body: Encodable { let prompt: String }
    return try await post(
      "/v1/managed-agents/\(agentID)/prompt",
      body: Body(prompt: prompt)
    )
  }

  public func openRouterModelCatalog() async throws -> OpenRouterModelCatalog {
    try await get("/v1/openrouter/models")
  }
}
