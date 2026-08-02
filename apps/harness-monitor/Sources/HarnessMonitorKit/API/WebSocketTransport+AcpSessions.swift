import Foundation

extension WebSocketTransport {
  public func managedAcpSessions(
    agentID: String,
    cwd: String?,
    cursor: String?
  ) async throws -> AcpProviderSessionPage {
    var params = managedAgentParams(agentID: agentID)
    if let cwd { params["cwd"] = .string(cwd) }
    if let cursor { params["cursor"] = .string(cursor) }
    let value = try await rpc(method: .managedAgentAcpSessions, params: .object(params))
    return try decodePolicyWire(value)
  }

  public func closeManagedAcpSession(agentID: String, sessionID: String) async throws {
    _ = try await acpSessionMutation(
      method: .managedAgentCloseAcpSession,
      agentID: agentID,
      sessionID: sessionID
    )
  }

  public func deleteManagedAcpSession(agentID: String, sessionID: String) async throws {
    _ = try await acpSessionMutation(
      method: .managedAgentDeleteAcpSession,
      agentID: agentID,
      sessionID: sessionID
    )
  }

  public func logoutManagedAcpAgent(agentID: String) async throws {
    let value = try await rpc(
      method: .managedAgentLogoutAcp,
      params: .object(managedAgentParams(agentID: agentID))
    )
    let _: AcpMutationAcknowledgement = try decodePolicyWire(value)
  }

  private func acpSessionMutation(
    method: WebSocketRPCMethod,
    agentID: String,
    sessionID: String
  ) async throws -> AcpMutationAcknowledgement {
    var params = managedAgentParams(agentID: agentID)
    params["agent_session_id"] = .string(sessionID)
    let value = try await rpc(method: method, params: .object(params))
    return try decodePolicyWire(value)
  }
}
