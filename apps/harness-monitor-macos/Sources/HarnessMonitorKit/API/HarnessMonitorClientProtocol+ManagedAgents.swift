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

  public func managedAgents(sessionID: HarnessSessionID) async throws -> ManagedAgentListResponse {
    try await managedAgents(sessionID: sessionID.rawValue)
  }

  public func managedAgent(agentID: ManagedAgentID) async throws -> ManagedAgentSnapshot {
    try await managedAgent(agentID: agentID.rawValue)
  }

  public func startManagedTerminalAgent(
    sessionID: HarnessSessionID,
    request: AgentTuiStartRequest
  ) async throws -> ManagedAgentSnapshot {
    try await startManagedTerminalAgent(sessionID: sessionID.rawValue, request: request)
  }

  public func startManagedCodexAgent(
    sessionID: HarnessSessionID,
    request: CodexRunRequest
  ) async throws -> ManagedAgentSnapshot {
    try await startManagedCodexAgent(sessionID: sessionID.rawValue, request: request)
  }

  public func startManagedAcpAgent(
    sessionID: HarnessSessionID,
    request: AcpAgentStartRequest
  ) async throws -> ManagedAgentSnapshot {
    try await startManagedAcpAgent(sessionID: sessionID.rawValue, request: request)
  }

  public func sendManagedAgentInput(
    agentID: ManagedAgentID,
    request: AgentTuiInputRequest
  ) async throws -> ManagedAgentSnapshot {
    try await sendManagedAgentInput(agentID: agentID.rawValue, request: request)
  }

  public func resizeManagedAgent(
    agentID: ManagedAgentID,
    request: AgentTuiResizeRequest
  ) async throws -> ManagedAgentSnapshot {
    try await resizeManagedAgent(agentID: agentID.rawValue, request: request)
  }

  public func stopManagedAgent(agentID: ManagedAgentID) async throws -> ManagedAgentSnapshot {
    try await stopManagedAgent(agentID: agentID.rawValue)
  }

  public func stopManagedAcpAgent(agentID: ManagedAgentID) async throws -> ManagedAgentSnapshot {
    try await stopManagedAcpAgent(agentID: agentID.rawValue)
  }

  public func steerManagedCodexAgent(
    agentID: ManagedAgentID,
    request: CodexSteerRequest
  ) async throws -> ManagedAgentSnapshot {
    try await steerManagedCodexAgent(agentID: agentID.rawValue, request: request)
  }

  public func interruptManagedCodexAgent(agentID: ManagedAgentID) async throws -> ManagedAgentSnapshot {
    try await interruptManagedCodexAgent(agentID: agentID.rawValue)
  }

  public func resolveManagedCodexApproval(
    agentID: ManagedAgentID,
    approvalID: CodexApprovalID,
    request: CodexApprovalDecisionRequest
  ) async throws -> ManagedAgentSnapshot {
    try await resolveManagedCodexApproval(
      agentID: agentID.rawValue,
      approvalID: approvalID.rawValue,
      request: request
    )
  }

  public func resolveManagedAcpPermission(
    agentID: ManagedAgentID,
    batchID: AcpPermissionBatchID,
    decision: AcpPermissionDecision
  ) async throws -> ManagedAgentSnapshot {
    try await resolveManagedAcpPermission(
      agentID: agentID.rawValue,
      batchID: batchID.rawValue,
      decision: decision
    )
  }

  public func acpInspect(sessionID: HarnessSessionID?) async throws -> AcpAgentInspectResponse {
    try await acpInspect(sessionID: sessionID?.rawValue)
  }

  public func acpTranscript(sessionID: HarnessSessionID) async throws -> AcpTranscriptResponse {
    try await acpTranscript(sessionID: sessionID.rawValue)
  }

  public func codexRuns(sessionID: HarnessSessionID) async throws -> CodexRunListResponse {
    try await codexRuns(sessionID: sessionID.rawValue)
  }

  public func codexRun(runID: ManagedAgentID) async throws -> CodexRunSnapshot {
    try await codexRun(runID: runID.rawValue)
  }

  public func startCodexRun(
    sessionID: HarnessSessionID,
    request: CodexRunRequest
  ) async throws -> CodexRunSnapshot {
    try await startCodexRun(sessionID: sessionID.rawValue, request: request)
  }

  public func steerCodexRun(
    runID: ManagedAgentID,
    request: CodexSteerRequest
  ) async throws -> CodexRunSnapshot {
    try await steerCodexRun(runID: runID.rawValue, request: request)
  }

  public func interruptCodexRun(runID: ManagedAgentID) async throws -> CodexRunSnapshot {
    try await interruptCodexRun(runID: runID.rawValue)
  }

  public func resolveCodexApproval(
    runID: ManagedAgentID,
    approvalID: CodexApprovalID,
    request: CodexApprovalDecisionRequest
  ) async throws -> CodexRunSnapshot {
    try await resolveCodexApproval(
      runID: runID.rawValue,
      approvalID: approvalID.rawValue,
      request: request
    )
  }

  public func agentTuis(sessionID: HarnessSessionID) async throws -> AgentTuiListResponse {
    try await agentTuis(sessionID: sessionID.rawValue)
  }

  public func agentTui(tuiID: ManagedAgentID) async throws -> AgentTuiSnapshot {
    try await agentTui(tuiID: tuiID.rawValue)
  }

  public func startAgentTui(
    sessionID: HarnessSessionID,
    request: AgentTuiStartRequest
  ) async throws -> AgentTuiSnapshot {
    try await startAgentTui(sessionID: sessionID.rawValue, request: request)
  }

  public func sendAgentTuiInput(
    tuiID: ManagedAgentID,
    request: AgentTuiInputRequest
  ) async throws -> AgentTuiSnapshot {
    try await sendAgentTuiInput(tuiID: tuiID.rawValue, request: request)
  }

  public func resizeAgentTui(
    tuiID: ManagedAgentID,
    request: AgentTuiResizeRequest
  ) async throws -> AgentTuiSnapshot {
    try await resizeAgentTui(tuiID: tuiID.rawValue, request: request)
  }

  public func stopAgentTui(tuiID: ManagedAgentID) async throws -> AgentTuiSnapshot {
    try await stopAgentTui(tuiID: tuiID.rawValue)
  }

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

  public func stopManagedAcpAgent(agentID _: String) async throws -> ManagedAgentSnapshot {
    throw HarnessMonitorAPIError.server(code: 501, message: "Managed agent unavailable.")
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

  public func resolveManagedAcpPermission(
    agentID _: String,
    batchID _: String,
    decision _: AcpPermissionDecision
  ) async throws -> ManagedAgentSnapshot {
    throw HarnessMonitorAPIError.server(code: 501, message: "Managed agent unavailable.")
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
