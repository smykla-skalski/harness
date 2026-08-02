import Foundation

public protocol HarnessMonitorAcpSessionClientProtocol: Sendable {
  func managedAcpSessions(
    agentID: String,
    cwd: String?,
    cursor: String?
  ) async throws -> AcpProviderSessionPage
  func closeManagedAcpSession(agentID: String, sessionID: String) async throws
  func deleteManagedAcpSession(agentID: String, sessionID: String) async throws
  func logoutManagedAcpAgent(agentID: String) async throws
}
