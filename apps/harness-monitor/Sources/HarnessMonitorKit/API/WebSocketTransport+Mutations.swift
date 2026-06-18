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

  public func deleteTask(
    sessionID: String,
    taskID: String,
    request: TaskDeleteRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(
      request,
      extra: ["session_id": .string(sessionID), "task_id": .string(taskID)]
    )
    let value = try await rpc(method: .taskDelete, params: params)
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
      extra: sessionAgentMutationParams(sessionID: sessionID, agentID: agentID)
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
      extra: sessionAgentMutationParams(sessionID: sessionID, agentID: agentID)
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

  public func archiveSession(
    sessionID: String,
    request: SessionArchiveRequest
  ) async throws -> SessionArchiveResponse {
    let params = try encodeParams(
      SessionArchiveRequestWire(request),
      extra: ["session_id": .string(sessionID)]
    )
    let value = try await rpc(method: .sessionArchive, params: params)
    let wire: SessionArchiveResponseWire = try decodePolicyWire(value)
    return SessionArchiveResponse(wire: wire)
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
      throw HarnessMonitorAPIError.server(code: 404, message: "Agents unavailable")
    }
    return tui
  }

  public func managedAgents(sessionID: String) async throws -> ManagedAgentListResponse {
    let value = try await rpc(
      method: .sessionManagedAgents,
      params: .object(sessionScopeParams(sessionID: sessionID))
    )
    let wire: ManagedAgentListResponseWire = try decodePolicyWire(value)
    return try ManagedAgentListResponse(wire: wire)
  }

  public func managedAgent(agentID: String) async throws -> ManagedAgentSnapshot {
    let value = try await rpc(
      method: .managedAgentDetail,
      params: .object(managedAgentParams(agentID: agentID))
    )
    let wire: ManagedAgentSnapshotWire = try decodePolicyWire(value)
    return try ManagedAgentSnapshot(wire: wire)
  }

  public func startManagedTerminalAgent(
    sessionID: String,
    request: AgentTuiStartRequest
  ) async throws -> ManagedAgentSnapshot {
    let params = try encodeParams(
      AgentTuiStartRequestWire(request),
      extra: sessionScopeParams(sessionID: sessionID)
    )
    let value = try await rpc(method: .managedAgentStartTerminal, params: params)
    let wire: ManagedAgentSnapshotWire = try decodePolicyWire(value)
    return try ManagedAgentSnapshot(wire: wire)
  }

  public func startManagedCodexAgent(
    sessionID: String,
    request: CodexRunRequest
  ) async throws -> ManagedAgentSnapshot {
    let params = try encodeParams(
      CodexRunRequestWire(request),
      extra: sessionScopeParams(sessionID: sessionID)
    )
    let value = try await rpc(method: .managedAgentStartCodex, params: params)
    let wire: ManagedAgentSnapshotWire = try decodePolicyWire(value)
    return try ManagedAgentSnapshot(wire: wire)
  }

  public func startManagedAcpAgent(
    sessionID: String,
    request: AcpAgentStartRequest
  ) async throws -> ManagedAgentSnapshot {
    let params = try encodeParams(
      AcpAgentStartRequestWire(request),
      extra: sessionScopeParams(sessionID: sessionID)
    )
    let value = try await rpc(method: .managedAgentStartAcp, params: params)
    let wire: ManagedAgentSnapshotWire = try decodePolicyWire(value)
    return try ManagedAgentSnapshot(wire: wire)
  }

  public func sendManagedAgentInput(
    agentID: String,
    request: AgentTuiInputRequest
  ) async throws -> ManagedAgentSnapshot {
    let params = try encodeParams(request, extra: managedAgentParams(agentID: agentID))
    let value = try await rpc(method: .managedAgentInput, params: params)
    let wire: ManagedAgentSnapshotWire = try decodePolicyWire(value)
    return try ManagedAgentSnapshot(wire: wire)
  }

  public func resizeManagedAgent(
    agentID: String,
    request: AgentTuiResizeRequest
  ) async throws -> ManagedAgentSnapshot {
    let params = try encodeParams(
      AgentTuiResizeRequestWire(request),
      extra: managedAgentParams(agentID: agentID)
    )
    let value = try await rpc(method: .managedAgentResize, params: params)
    let wire: ManagedAgentSnapshotWire = try decodePolicyWire(value)
    return try ManagedAgentSnapshot(wire: wire)
  }

  public func stopManagedAgent(agentID: String) async throws -> ManagedAgentSnapshot {
    let value = try await rpc(
      method: .managedAgentStop,
      params: .object(managedAgentParams(agentID: agentID))
    )
    let wire: ManagedAgentSnapshotWire = try decodePolicyWire(value)
    return try ManagedAgentSnapshot(wire: wire)
  }

  public func stopManagedAcpAgent(agentID: String) async throws -> ManagedAgentSnapshot {
    let value = try await rpc(
      method: .managedAgentStopAcp,
      params: .object(managedAgentParams(agentID: agentID))
    )
    let wire: ManagedAgentSnapshotWire = try decodePolicyWire(value)
    return try ManagedAgentSnapshot(wire: wire)
  }

  public func promptManagedAcpAgent(
    agentID: String,
    prompt: String
  ) async throws -> ManagedAgentSnapshot {
    var params = managedAgentParams(agentID: agentID)
    params["prompt"] = .string(prompt)
    let value = try await rpc(method: .managedAgentPromptAcp, params: .object(params))
    let wire: ManagedAgentSnapshotWire = try decodePolicyWire(value)
    return try ManagedAgentSnapshot(wire: wire)
  }

  public func steerManagedCodexAgent(
    agentID: String,
    request: CodexSteerRequest
  ) async throws -> ManagedAgentSnapshot {
    let params = try encodeParams(
      CodexSteerRequestWire(request),
      extra: managedAgentParams(agentID: agentID)
    )
    let value = try await rpc(method: .managedAgentSteerCodex, params: params)
    let wire: ManagedAgentSnapshotWire = try decodePolicyWire(value)
    return try ManagedAgentSnapshot(wire: wire)
  }

  public func interruptManagedCodexAgent(agentID: String) async throws -> ManagedAgentSnapshot {
    let value = try await rpc(
      method: .managedAgentInterruptCodex,
      params: .object(managedAgentParams(agentID: agentID))
    )
    let wire: ManagedAgentSnapshotWire = try decodePolicyWire(value)
    return try ManagedAgentSnapshot(wire: wire)
  }

  public func resolveManagedCodexApproval(
    agentID: String,
    approvalID: String,
    request: CodexApprovalDecisionRequest
  ) async throws -> ManagedAgentSnapshot {
    let params = try encodeParams(
      CodexApprovalDecisionRequestWire(request),
      extra: managedAgentParams(agentID: agentID).merging(
        ["approval_id": .string(approvalID)]
      ) { _, newValue in newValue }
    )
    let value = try await rpc(method: .managedAgentResolveCodexApproval, params: params)
    let wire: ManagedAgentSnapshotWire = try decodePolicyWire(value)
    return try ManagedAgentSnapshot(wire: wire)
  }

  public func resolveManagedAcpPermission(
    agentID: String,
    batchID: String,
    decision: AcpPermissionDecision
  ) async throws -> ManagedAgentSnapshot {
    let params = try encodeParams(
      AcpPermissionDecisionWire(decision),
      extra: managedAgentParams(agentID: agentID).merging(
        ["batch_id": .string(batchID)]
      ) { _, newValue in newValue }
    )
    let value = try await rpc(method: .managedAgentResolveAcpPermission, params: params)
    let wire: ManagedAgentSnapshotWire = try decodePolicyWire(value)
    return try ManagedAgentSnapshot(wire: wire)
  }

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
