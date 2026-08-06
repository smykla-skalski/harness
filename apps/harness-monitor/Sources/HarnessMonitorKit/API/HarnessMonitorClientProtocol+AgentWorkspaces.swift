import Foundation

extension HarnessMonitorClientProtocol {
  public func agentWorkspaces() async throws -> AgentWorkspaceListResponse {
    AgentWorkspaceListResponse(workspaces: [], conflicts: [])
  }
}
