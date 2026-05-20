import Foundation

extension HarnessMonitorClientProtocol {
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

  public func promptManagedAcpAgent(
    agentID: ManagedAgentID,
    prompt: String
  ) async throws -> ManagedAgentSnapshot {
    try await promptManagedAcpAgent(agentID: agentID.rawValue, prompt: prompt)
  }

  public func steerManagedCodexAgent(
    agentID: ManagedAgentID,
    request: CodexSteerRequest
  ) async throws -> ManagedAgentSnapshot {
    try await steerManagedCodexAgent(agentID: agentID.rawValue, request: request)
  }

  public func interruptManagedCodexAgent(agentID: ManagedAgentID) async throws
    -> ManagedAgentSnapshot
  {
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

  public func codexInspect(sessionID: HarnessSessionID?) async throws
    -> CodexAgentInspectResponse
  {
    try await codexInspect(sessionID: sessionID?.rawValue)
  }

  public func codexTranscript(sessionID: HarnessSessionID) async throws -> CodexTranscriptResponse {
    try await codexTranscript(sessionID: sessionID.rawValue)
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
}
