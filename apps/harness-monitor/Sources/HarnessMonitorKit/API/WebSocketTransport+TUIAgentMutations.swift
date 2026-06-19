import Foundation

// Agent TUI convenience wrappers over managed-agent WebSocket mutations.
extension WebSocketTransport {
  public func startAgentTui(
    sessionID: String,
    request: AgentTuiStartRequest
  ) async throws -> AgentTuiSnapshot {
    let snapshot = try await startManagedTerminalAgent(sessionID: sessionID, request: request)
    guard let tui = snapshot.terminal else {
      throw HarnessMonitorAPIError.server(
        code: 500,
        message: "Managed agent start did not return a terminal snapshot"
      )
    }
    return tui
  }

  public func sendAgentTuiInput(
    tuiID: String,
    request: AgentTuiInputRequest
  ) async throws -> AgentTuiSnapshot {
    let snapshot = try await sendManagedAgentInput(agentID: tuiID, request: request)
    guard let tui = snapshot.terminal else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Agents unavailable")
    }
    return tui
  }

  public func resizeAgentTui(
    tuiID: String,
    request: AgentTuiResizeRequest
  ) async throws -> AgentTuiSnapshot {
    let snapshot = try await resizeManagedAgent(agentID: tuiID, request: request)
    guard let tui = snapshot.terminal else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Agents unavailable")
    }
    return tui
  }

  public func stopAgentTui(tuiID: String) async throws -> AgentTuiSnapshot {
    let snapshot = try await stopManagedAgent(agentID: tuiID)
    guard let tui = snapshot.terminal else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Agents unavailable")
    }
    return tui
  }
}
