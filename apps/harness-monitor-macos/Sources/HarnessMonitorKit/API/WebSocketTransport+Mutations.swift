import Foundation

extension WebSocketTransport {
  public func createTask(
    sessionID: String,
    request: TaskCreateRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(request, extra: ["session_id": .string(sessionID)])
    let value = try await rpc(method: .taskCreate, params: params)
    return try decode(value)
  }

  public func assignTask(
    sessionID: String,
    taskID: String,
    request: TaskAssignRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(
      request,
      extra: ["session_id": .string(sessionID), "task_id": .string(taskID)]
    )
    let value = try await rpc(method: .taskAssign, params: params)
    return try decode(value)
  }

  public func dropTask(
    sessionID: String,
    taskID: String,
    request: TaskDropRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(
      request,
      extra: ["session_id": .string(sessionID), "task_id": .string(taskID)]
    )
    let value = try await rpc(method: .taskDrop, params: params)
    return try decode(value)
  }

  public func updateTaskQueuePolicy(
    sessionID: String,
    taskID: String,
    request: TaskQueuePolicyRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(
      request,
      extra: ["session_id": .string(sessionID), "task_id": .string(taskID)]
    )
    let value = try await rpc(method: .taskQueuePolicy, params: params)
    return try decode(value)
  }

  public func updateTask(
    sessionID: String,
    taskID: String,
    request: TaskUpdateRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(
      request,
      extra: ["session_id": .string(sessionID), "task_id": .string(taskID)]
    )
    let value = try await rpc(method: .taskUpdate, params: params)
    return try decode(value)
  }

  public func checkpointTask(
    sessionID: String,
    taskID: String,
    request: TaskCheckpointRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(
      request,
      extra: ["session_id": .string(sessionID), "task_id": .string(taskID)]
    )
    let value = try await rpc(method: .taskCheckpoint, params: params)
    return try decode(value)
  }

  public func changeRole(
    sessionID: String,
    agentID: String,
    request: RoleChangeRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(
      request,
      extra: ["session_id": .string(sessionID), "agent_id": .string(agentID)]
    )
    let value = try await rpc(method: .agentChangeRole, params: params)
    return try decode(value)
  }

  public func removeAgent(
    sessionID: String,
    agentID: String,
    request: AgentRemoveRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(
      request,
      extra: ["session_id": .string(sessionID), "agent_id": .string(agentID)]
    )
    let value = try await rpc(method: .agentRemove, params: params)
    return try decode(value)
  }

  public func transferLeader(
    sessionID: String,
    request: LeaderTransferRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(request, extra: ["session_id": .string(sessionID)])
    let value = try await rpc(method: .leaderTransfer, params: params)
    return try decode(value)
  }

  public func startSession(request: SessionStartRequest) async throws -> SessionStartResult {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .sessionStart, params: params)
    let response: SessionStartMutationResponse = try decode(value)
    return response.result
  }

  public func adoptSession(
    bookmarkID: String?,
    sessionRoot: URL
  ) async throws -> SessionSummary {
    struct Response: Decodable { let state: SessionSummary }

    let request = AdoptSessionRequest(
      bookmarkID: bookmarkID,
      sessionRoot: sessionRoot.path
    )
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .sessionAdopt, params: params)
    let response: Response = try decode(value)
    return response.state
  }

  public func endSession(
    sessionID: String,
    request: SessionEndRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(request, extra: ["session_id": .string(sessionID)])
    let value = try await rpc(method: .sessionEnd, params: params)
    return try decode(value)
  }

  public func sendSignal(
    sessionID: String,
    request: SignalSendRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(request, extra: ["session_id": .string(sessionID)])
    let value = try await rpc(method: .signalSend, params: params)
    return try decode(value)
  }

  public func cancelSignal(
    sessionID: String,
    request: SignalCancelRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(request, extra: ["session_id": .string(sessionID)])
    let value = try await rpc(method: .signalCancel, params: params)
    return try decode(value)
  }

  public func observeSession(
    sessionID: String,
    request: ObserveSessionRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(request, extra: ["session_id": .string(sessionID)])
    let value = try await rpc(method: .sessionObserve, params: params)
    return try decode(value)
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

  public func managedAgents(sessionID: String) async throws -> ManagedAgentListResponse {
    let value = try await rpc(
      method: .sessionManagedAgents,
      params: .object(["session_id": .string(sessionID)])
    )
    return try decode(value)
  }

  public func managedAgent(agentID: String) async throws -> ManagedAgentSnapshot {
    let value = try await rpc(
      method: .managedAgentDetail,
      params: .object(["agent_id": .string(agentID)])
    )
    return try decode(value)
  }

  public func startManagedTerminalAgent(
    sessionID: String,
    request: AgentTuiStartRequest
  ) async throws -> ManagedAgentSnapshot {
    let params = try encodeParams(request, extra: ["session_id": .string(sessionID)])
    let value = try await rpc(method: .managedAgentStartTerminal, params: params)
    return try decode(value)
  }

  public func startManagedCodexAgent(
    sessionID: String,
    request: CodexRunRequest
  ) async throws -> ManagedAgentSnapshot {
    let params = try encodeParams(request, extra: ["session_id": .string(sessionID)])
    let value = try await rpc(method: .managedAgentStartCodex, params: params)
    return try decode(value)
  }

  public func startManagedAcpAgent(
    sessionID: String,
    request: AcpAgentStartRequest
  ) async throws -> ManagedAgentSnapshot {
    let params = try encodeParams(request, extra: ["session_id": .string(sessionID)])
    let value = try await rpc(method: .managedAgentStartAcp, params: params)
    return try decode(value)
  }

  public func sendManagedAgentInput(
    agentID: String,
    request: AgentTuiInputRequest
  ) async throws -> ManagedAgentSnapshot {
    let params = try encodeParams(request, extra: ["agent_id": .string(agentID)])
    let value = try await rpc(method: .managedAgentInput, params: params)
    return try decode(value)
  }

  public func resizeManagedAgent(
    agentID: String,
    request: AgentTuiResizeRequest
  ) async throws -> ManagedAgentSnapshot {
    let params = try encodeParams(request, extra: ["agent_id": .string(agentID)])
    let value = try await rpc(method: .managedAgentResize, params: params)
    return try decode(value)
  }

  public func stopManagedAgent(agentID: String) async throws -> ManagedAgentSnapshot {
    let value = try await rpc(
      method: .managedAgentStop,
      params: .object(["agent_id": .string(agentID)])
    )
    return try decode(value)
  }

  public func steerManagedCodexAgent(
    agentID: String,
    request: CodexSteerRequest
  ) async throws -> ManagedAgentSnapshot {
    let params = try encodeParams(request, extra: ["agent_id": .string(agentID)])
    let value = try await rpc(method: .managedAgentSteerCodex, params: params)
    return try decode(value)
  }

  public func interruptManagedCodexAgent(agentID: String) async throws -> ManagedAgentSnapshot {
    let value = try await rpc(
      method: .managedAgentInterruptCodex,
      params: .object(["agent_id": .string(agentID)])
    )
    return try decode(value)
  }

  public func resolveManagedCodexApproval(
    agentID: String,
    approvalID: String,
    request: CodexApprovalDecisionRequest
  ) async throws -> ManagedAgentSnapshot {
    let params = try encodeParams(
      request,
      extra: [
        "agent_id": .string(agentID),
        "approval_id": .string(approvalID),
      ]
    )
    let value = try await rpc(method: .managedAgentResolveCodexApproval, params: params)
    return try decode(value)
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

  public func personas() async throws -> [AgentPersona] {
    try await configuration().personas
  }

  public func runtimeModelCatalogs() async throws -> [RuntimeModelCatalog] {
    try await configuration().runtimeModels
  }

  public func acpAgentDescriptors() async throws -> [AcpAgentDescriptor] {
    try await configuration().acpAgents
  }

  public func runtimeProbeResults() async throws -> AcpRuntimeProbeResponse {
    if let cached = try await configuration().runtimeProbe {
      return cached
    }
    let value = try await rpc(method: .runtimesProbe)
    return try decode(value)
  }

  public func acpInspect(sessionID: String?) async throws -> AcpAgentInspectResponse {
    var params: [String: JSONValue] = [:]
    if let sessionID {
      params["session_id"] = .string(sessionID)
    }
    let value = try await rpc(method: .managedAgentAcpInspect, params: .object(params))
    return try decode(value)
  }

  public func configuration() async throws -> MonitorConfiguration {
    if let cached = cachedConfiguration {
      return cached
    }
    return try await withCheckedThrowingContinuation { continuation in
      configurationWaiters.append(continuation)
    }
  }

  public func logLevel() async throws -> LogLevelResponse {
    let value = try await rpc(method: .daemonLogLevel)
    return try decode(value)
  }

  public func setLogLevel(_ level: String) async throws -> LogLevelResponse {
    let params = JSONValue.object(["level": .string(level)])
    let value = try await rpc(method: .daemonSetLogLevel, params: params)
    return try decode(value)
  }

  public func startVoiceSession(
    sessionID: String,
    request: VoiceSessionStartRequest
  ) async throws -> VoiceSessionStartResponse {
    let params = try encodeParams(request, extra: ["session_id": .string(sessionID)])
    let value = try await rpc(method: .voiceStartSession, params: params)
    return try decode(value)
  }

  public func appendVoiceAudioChunk(
    voiceSessionID: String,
    request: VoiceAudioChunkRequest
  ) async throws -> VoiceSessionMutationResponse {
    let params = try encodeParams(request, extra: ["voice_session_id": .string(voiceSessionID)])
    let value = try await rpc(method: .voiceAppendAudio, params: params)
    return try decode(value)
  }

  public func appendVoiceTranscript(
    voiceSessionID: String,
    request: VoiceTranscriptUpdateRequest
  ) async throws -> VoiceSessionMutationResponse {
    let params = try encodeParams(request, extra: ["voice_session_id": .string(voiceSessionID)])
    let value = try await rpc(method: .voiceAppendTranscript, params: params)
    return try decode(value)
  }

  public func finishVoiceSession(
    voiceSessionID: String,
    request: VoiceSessionFinishRequest
  ) async throws -> VoiceSessionMutationResponse {
    let params = try encodeParams(request, extra: ["voice_session_id": .string(voiceSessionID)])
    let value = try await rpc(method: .voiceFinishSession, params: params)
    return try decode(value)
  }
}
