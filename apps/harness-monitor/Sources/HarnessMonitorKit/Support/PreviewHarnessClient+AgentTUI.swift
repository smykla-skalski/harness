import Foundation

extension PreviewHarnessClient {
  public func agentTuis(sessionID: String) async throws -> AgentTuiListResponse {
    try await performReadDelay(for: EnvironmentKeys.agentTuisDelay)
    return AgentTuiListResponse(tuis: await state.agentTuis(sessionID: sessionID))
  }

  public func agentTui(tuiID: String) async throws -> AgentTuiSnapshot {
    guard let tui = await state.agentTui(tuiID: tuiID) else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Agents unavailable")
    }
    return tui
  }

  public func startAgentTui(
    sessionID: String,
    request: AgentTuiStartRequest
  ) async throws -> AgentTuiSnapshot {
    try await performActionDelay()
    return await state.startAgentTui(sessionID: sessionID, request: request)
  }

  public func sendAgentTuiInput(
    tuiID: String,
    request: AgentTuiInputRequest
  ) async throws -> AgentTuiSnapshot {
    try await performActionDelay()
    guard let updatedTui = await state.sendAgentTuiInput(tuiID: tuiID, request: request) else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Agents unavailable")
    }
    return updatedTui
  }

  public func resizeAgentTui(
    tuiID: String,
    request: AgentTuiResizeRequest
  ) async throws -> AgentTuiSnapshot {
    try await performActionDelay()
    guard let updatedTui = await state.resizeAgentTui(tuiID: tuiID, request: request) else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Agents unavailable")
    }
    return updatedTui
  }

  public func stopAgentTui(tuiID: String) async throws -> AgentTuiSnapshot {
    try await performActionDelay()
    guard let updatedTui = await state.stopAgentTui(tuiID: tuiID) else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Agents unavailable")
    }
    return updatedTui
  }
}
