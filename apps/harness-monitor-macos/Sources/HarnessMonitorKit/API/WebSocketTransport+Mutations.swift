import Foundation

extension WebSocketTransport {
  public func createTask(
    sessionID: String,
    request: TaskCreateRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(request, extra: ["session_id": .string(sessionID)])
    let value = try await send(method: "task.create", params: params)
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
    let value = try await send(method: "task.assign", params: params)
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
    let value = try await send(method: "task.drop", params: params)
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
    let value = try await send(method: "task.queue_policy", params: params)
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
    let value = try await send(method: "task.update", params: params)
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
    let value = try await send(method: "task.checkpoint", params: params)
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
    let value = try await send(method: "agent.change_role", params: params)
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
    let value = try await send(method: "agent.remove", params: params)
    return try decode(value)
  }

  public func transferLeader(
    sessionID: String,
    request: LeaderTransferRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(request, extra: ["session_id": .string(sessionID)])
    let value = try await send(method: "leader.transfer", params: params)
    return try decode(value)
  }

  public func endSession(
    sessionID: String,
    request: SessionEndRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(request, extra: ["session_id": .string(sessionID)])
    let value = try await send(method: "session.end", params: params)
    return try decode(value)
  }

  public func sendSignal(
    sessionID: String,
    request: SignalSendRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(request, extra: ["session_id": .string(sessionID)])
    let value = try await send(method: "signal.send", params: params)
    return try decode(value)
  }

  public func cancelSignal(
    sessionID: String,
    request: SignalCancelRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(request, extra: ["session_id": .string(sessionID)])
    let value = try await send(method: "signal.cancel", params: params)
    return try decode(value)
  }

  public func observeSession(
    sessionID: String,
    request: ObserveSessionRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(request, extra: ["session_id": .string(sessionID)])
    let value = try await send(method: "session.observe", params: params)
    return try decode(value)
  }

  public func agentTuis(sessionID: String) async throws -> AgentTuiListResponse {
    let value = try await send(
      method: "session.agent_tuis",
      params: .object(["session_id": .string(sessionID)])
    )
    let tuis: [AgentTuiSnapshot] = try decode(value)
    return AgentTuiListResponse(tuis: tuis)
  }

  public func agentTui(tuiID: String) async throws -> AgentTuiSnapshot {
    let value = try await send(
      method: "agent_tui.detail",
      params: .object(["tui_id": .string(tuiID)])
    )
    return try decode(value)
  }

  public func startAgentTui(
    sessionID: String,
    request: AgentTuiStartRequest
  ) async throws -> AgentTuiSnapshot {
    try await httpFallbackClient.startAgentTui(sessionID: sessionID, request: request)
  }

  public func sendAgentTuiInput(
    tuiID: String,
    request: AgentTuiInputRequest
  ) async throws -> AgentTuiSnapshot {
    try await httpFallbackClient.sendAgentTuiInput(tuiID: tuiID, request: request)
  }

  public func resizeAgentTui(
    tuiID: String,
    request: AgentTuiResizeRequest
  ) async throws -> AgentTuiSnapshot {
    try await httpFallbackClient.resizeAgentTui(tuiID: tuiID, request: request)
  }

  public func stopAgentTui(tuiID: String) async throws -> AgentTuiSnapshot {
    try await httpFallbackClient.stopAgentTui(tuiID: tuiID)
  }

  public func personas() async throws -> [AgentPersona] {
    try await httpFallbackClient.personas()
  }

  public func logLevel() async throws -> LogLevelResponse {
    let value = try await send(method: "daemon.log_level")
    return try decode(value)
  }

  public func setLogLevel(_ level: String) async throws -> LogLevelResponse {
    let params = JSONValue.object(["level": .string(level)])
    let value = try await send(method: "daemon.set_log_level", params: params)
    return try decode(value)
  }
}
