import Foundation

extension HarnessMonitorClientProtocol {
  public func changeRole(
    sessionID: HarnessSessionID,
    sessionAgentID: SessionAgentID,
    request: RoleChangeRequest
  ) async throws -> SessionDetail {
    try await changeRole(
      sessionID: sessionID.rawValue,
      agentID: sessionAgentID.rawValue,
      request: request
    )
  }

  public func removeAgent(
    sessionID: HarnessSessionID,
    sessionAgentID: SessionAgentID,
    request: AgentRemoveRequest
  ) async throws -> SessionDetail {
    try await removeAgent(
      sessionID: sessionID.rawValue,
      agentID: sessionAgentID.rawValue,
      request: request
    )
  }
}
