import Foundation

extension HarnessMonitorAPIClient {
  public func startManagedOpenRouterAgent(
    sessionID: String,
    request: OpenRouterStartRequest
  ) async throws -> ManagedAgentSnapshot {
    let snapshot: OpenRouterRunSnapshot = try await post(
      "/v1/sessions/\(sessionID)/managed-agents/openrouter",
      body: request
    )
    return .openRouter(snapshot)
  }

  public func listManagedOpenRouterAgents(
    sessionID: String
  ) async throws -> OpenRouterRunListResponse {
    try await get("/v1/sessions/\(sessionID)/managed-agents/openrouter")
  }

  public func getManagedOpenRouterAgent(
    managedAgentID: String
  ) async throws -> OpenRouterRunSnapshot {
    try await get("/v1/managed-agents/\(managedAgentID)/openrouter")
  }

  public func promptManagedOpenRouterAgent(
    managedAgentID: String,
    prompt: String
  ) async throws -> OpenRouterRunSnapshot {
    try await post(
      "/v1/managed-agents/\(managedAgentID)/openrouter/prompt",
      body: OpenRouterPromptRequest(prompt: prompt)
    )
  }

  public func cancelManagedOpenRouterAgent(
    managedAgentID: String
  ) async throws -> OpenRouterRunSnapshot {
    try await post(
      "/v1/managed-agents/\(managedAgentID)/openrouter/cancel",
      body: EmptyRequest()
    )
  }

  public func listOpenRouterModels() async throws -> OpenRouterModelListResponse {
    try await get("/v1/managed-agents/openrouter/models")
  }
}

private struct EmptyRequest: Codable {}
