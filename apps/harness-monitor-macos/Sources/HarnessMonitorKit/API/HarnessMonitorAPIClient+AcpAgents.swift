import Foundation

extension HarnessMonitorAPIClient {
  public func startManagedAcpAgent(
    sessionID: String,
    request: AcpAgentStartRequest
  ) async throws -> ManagedAgentSnapshot {
    try await post("/v1/sessions/\(sessionID)/managed-agents/acp", body: request)
  }
}
