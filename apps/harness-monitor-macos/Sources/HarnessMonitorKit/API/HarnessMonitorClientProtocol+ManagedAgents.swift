import Foundation

extension HarnessMonitorClientProtocol {
  public func managedAgents(sessionID: String) async throws -> ManagedAgentListResponse {
    let terminals = try await agentTuis(sessionID: sessionID)
    let codexRuns = try await codexRuns(sessionID: sessionID)
    return ManagedAgentListResponse(
      agents:
        terminals.tuis.map(ManagedAgentSnapshot.terminal)
        + codexRuns.runs.map(ManagedAgentSnapshot.codex)
    )
  }

  public func managedAgent(agentID: String) async throws -> ManagedAgentSnapshot {
    if let terminal = try? await agentTui(tuiID: agentID) {
      return .terminal(terminal)
    }
    return .codex(try await codexRun(runID: agentID))
  }

  public func startManagedTerminalAgent(
    sessionID: String,
    request: AgentTuiStartRequest
  ) async throws -> ManagedAgentSnapshot {
    .terminal(try await startAgentTui(sessionID: sessionID, request: request))
  }

  public func startManagedCodexAgent(
    sessionID: String,
    request: CodexRunRequest
  ) async throws -> ManagedAgentSnapshot {
    .codex(try await startCodexRun(sessionID: sessionID, request: request))
  }

  public func startManagedAcpAgent(
    sessionID _: String,
    request _: AcpAgentStartRequest
  ) async throws -> ManagedAgentSnapshot {
    throw HarnessMonitorAPIError.server(code: 501, message: "Managed agent unavailable.")
  }

  public func sendManagedAgentInput(
    agentID: String,
    request: AgentTuiInputRequest
  ) async throws -> ManagedAgentSnapshot {
    .terminal(try await sendAgentTuiInput(tuiID: agentID, request: request))
  }

  public func resizeManagedAgent(
    agentID: String,
    request: AgentTuiResizeRequest
  ) async throws -> ManagedAgentSnapshot {
    .terminal(try await resizeAgentTui(tuiID: agentID, request: request))
  }

  public func stopManagedAgent(agentID: String) async throws -> ManagedAgentSnapshot {
    .terminal(try await stopAgentTui(tuiID: agentID))
  }

  public func steerManagedCodexAgent(
    agentID: String,
    request: CodexSteerRequest
  ) async throws -> ManagedAgentSnapshot {
    .codex(try await steerCodexRun(runID: agentID, request: request))
  }

  public func interruptManagedCodexAgent(agentID: String) async throws -> ManagedAgentSnapshot {
    .codex(try await interruptCodexRun(runID: agentID))
  }

  public func resolveManagedCodexApproval(
    agentID: String,
    approvalID: String,
    request: CodexApprovalDecisionRequest
  ) async throws -> ManagedAgentSnapshot {
    .codex(
      try await resolveCodexApproval(
        runID: agentID,
        approvalID: approvalID,
        request: request
      )
    )
  }

  public func codexRuns(sessionID: String) async throws -> CodexRunListResponse {
    let agents = try await managedAgents(sessionID: sessionID)
    return CodexRunListResponse(
      runs: agents.agents.compactMap { $0.codex }
    )
  }

  public func codexRun(runID: String) async throws -> CodexRunSnapshot {
    let snapshot = try await managedAgent(agentID: runID)
    guard let codex = snapshot.codex else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Codex run unavailable.")
    }
    return codex
  }

  public func startCodexRun(
    sessionID: String,
    request: CodexRunRequest
  ) async throws -> CodexRunSnapshot {
    let snapshot = try await startManagedCodexAgent(sessionID: sessionID, request: request)
    guard let codex = snapshot.codex else {
      throw HarnessMonitorAPIError.server(
        code: 500,
        message: "Managed Codex agent did not return a Codex snapshot."
      )
    }
    return codex
  }

  public func steerCodexRun(
    runID: String,
    request: CodexSteerRequest
  ) async throws -> CodexRunSnapshot {
    let snapshot = try await steerManagedCodexAgent(agentID: runID, request: request)
    guard let codex = snapshot.codex else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Codex run unavailable.")
    }
    return codex
  }

  public func interruptCodexRun(runID: String) async throws -> CodexRunSnapshot {
    let snapshot = try await interruptManagedCodexAgent(agentID: runID)
    guard let codex = snapshot.codex else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Codex run unavailable.")
    }
    return codex
  }

  public func resolveCodexApproval(
    runID: String,
    approvalID: String,
    request: CodexApprovalDecisionRequest
  ) async throws -> CodexRunSnapshot {
    let snapshot = try await resolveManagedCodexApproval(
      agentID: runID,
      approvalID: approvalID,
      request: request
    )
    guard let codex = snapshot.codex else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Codex run unavailable.")
    }
    return codex
  }

  public func agentTuis(sessionID: String) async throws -> AgentTuiListResponse {
    let agents = try await managedAgents(sessionID: sessionID)
    return AgentTuiListResponse(tuis: agents.agents.compactMap { $0.terminal })
  }

  public func agentTui(tuiID: String) async throws -> AgentTuiSnapshot {
    let snapshot = try await managedAgent(agentID: tuiID)
    guard let tui = snapshot.terminal else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Agents unavailable.")
    }
    return tui
  }

  public func startAgentTui(
    sessionID: String,
    request: AgentTuiStartRequest
  ) async throws -> AgentTuiSnapshot {
    let snapshot = try await startManagedTerminalAgent(sessionID: sessionID, request: request)
    guard let tui = snapshot.terminal else {
      throw HarnessMonitorAPIError.server(
        code: 500,
        message: "Managed agent start did not return a terminal snapshot."
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
      throw HarnessMonitorAPIError.server(code: 404, message: "Agents unavailable.")
    }
    return tui
  }

  public func resizeAgentTui(
    tuiID: String,
    request: AgentTuiResizeRequest
  ) async throws -> AgentTuiSnapshot {
    let snapshot = try await resizeManagedAgent(agentID: tuiID, request: request)
    guard let tui = snapshot.terminal else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Agents unavailable.")
    }
    return tui
  }

  public func stopAgentTui(tuiID: String) async throws -> AgentTuiSnapshot {
    let snapshot = try await stopManagedAgent(agentID: tuiID)
    guard let tui = snapshot.terminal else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Agents unavailable.")
    }
    return tui
  }

  public func startVoiceSession(
    sessionID _: String,
    request _: VoiceSessionStartRequest
  ) async throws -> VoiceSessionStartResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Voice capture unavailable.")
  }

  public func appendVoiceAudioChunk(
    voiceSessionID _: String,
    request _: VoiceAudioChunkRequest
  ) async throws -> VoiceSessionMutationResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Voice capture unavailable.")
  }

  public func appendVoiceTranscript(
    voiceSessionID _: String,
    request _: VoiceTranscriptUpdateRequest
  ) async throws -> VoiceSessionMutationResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Voice capture unavailable.")
  }

  public func finishVoiceSession(
    voiceSessionID _: String,
    request _: VoiceSessionFinishRequest
  ) async throws -> VoiceSessionMutationResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Voice capture unavailable.")
  }
}
