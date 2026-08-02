import Foundation

extension HarnessMonitorAPIClient {
  public func startManagedAcpAgent(
    sessionID: String,
    request: AcpAgentStartRequest
  ) async throws -> ManagedAgentSnapshot {
    let wire: ManagedAgentSnapshotWire = try await post(
      "/v1/sessions/\(sessionID)/managed-agents/acp",
      body: AcpAgentStartRequestWire(request),
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

  public func managedAcpSessions(
    agentID: String,
    cwd: String?,
    cursor: String?
  ) async throws -> AcpProviderSessionPage {
    var queryItems: [URLQueryItem] = []
    if let cwd { queryItems.append(URLQueryItem(name: "cwd", value: cwd)) }
    if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
    return try await get(
      "/v1/managed-agents/\(agentID)/sessions",
      queryItems: queryItems,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func closeManagedAcpSession(agentID: String, sessionID: String) async throws {
    let _: AcpMutationAcknowledgement = try await post(
      "/v1/managed-agents/\(agentID)/sessions/\(sessionID)/close",
      body: EmptyBody(),
      decoder: PolicyWireCoding.decoder
    )
  }

  public func deleteManagedAcpSession(agentID: String, sessionID: String) async throws {
    let _: AcpMutationAcknowledgement = try await delete(
      "/v1/managed-agents/\(agentID)/sessions/\(sessionID)",
      decoder: PolicyWireCoding.decoder
    )
  }

  public func logoutManagedAcpAgent(agentID: String) async throws {
    let _: AcpMutationAcknowledgement = try await post(
      "/v1/managed-agents/\(agentID)/logout",
      body: EmptyBody(),
      decoder: PolicyWireCoding.decoder
    )
  }

  public func openRouterModelCatalog() async throws -> OpenRouterModelCatalogResponse {
    try await get("/v1/openrouter/models", decoder: PolicyWireCoding.decoder)
  }
}
