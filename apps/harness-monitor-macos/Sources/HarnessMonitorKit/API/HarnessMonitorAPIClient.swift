import Foundation

public final class HarnessMonitorAPIClient: HarnessMonitorClientProtocol {
  static let requestTimeoutInterval: TimeInterval = 15
  static let resourceTimeoutInterval: TimeInterval = 30

  let connection: HarnessMonitorConnection
  let decoder: JSONDecoder
  let encoder: JSONEncoder
  let session: URLSession

  public init(connection: HarnessMonitorConnection, session: URLSession? = nil) {
    self.connection = connection

    if let session {
      self.session = session
    } else {
      let configuration = URLSessionConfiguration.default
      configuration.timeoutIntervalForRequest = Self.requestTimeoutInterval
      configuration.timeoutIntervalForResource = Self.resourceTimeoutInterval
      self.session = URLSession(configuration: configuration)
    }

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    self.decoder = decoder

    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    self.encoder = encoder
  }

  public func health() async throws -> HealthResponse {
    try await get("/v1/health")
  }

  public func diagnostics() async throws -> DaemonDiagnosticsReport {
    try await get("/v1/diagnostics")
  }

  public func stopDaemon() async throws -> DaemonControlResponse {
    try await post("/v1/daemon/stop", body: EmptyBody())
  }

  public func reconfigureHostBridge(
    request: HostBridgeReconfigureRequest
  ) async throws -> BridgeStatusReport {
    try await post("/v1/bridge/reconfigure", body: request)
  }

  public func projects() async throws -> [ProjectSummary] {
    try await get("/v1/projects")
  }

  public func sessions() async throws -> [SessionSummary] {
    try await get("/v1/sessions")
  }

  public func sessionDetail(id: String, scope: String?) async throws -> SessionDetail {
    if let scope {
      return try await get("/v1/sessions/\(id)?scope=\(scope)")
    }
    return try await get("/v1/sessions/\(id)")
  }

  public func timeline(sessionID: String) async throws -> [TimelineEntry] {
    try await timeline(sessionID: sessionID, scope: .full)
  }

  public func timelineWindow(sessionID: String, request: TimelineWindowRequest) async throws
    -> TimelineWindowResponse
  {
    let queryItems = timelineWindowQueryItems(for: request)
    return try await get("/v1/sessions/\(sessionID)/timeline", queryItems: queryItems)
  }

  public func timelineWindow(
    sessionID: String,
    request: TimelineWindowRequest,
    onBatch: @escaping TimelineWindowBatchHandler
  ) async throws -> TimelineWindowResponse {
    let response = try await timelineWindow(sessionID: sessionID, request: request)
    await onBatch(response, 0, 1)
    return response
  }

  public func timeline(sessionID: String, scope: TimelineScope) async throws -> [TimelineEntry] {
    if scope == .summary {
      return try await get("/v1/sessions/\(sessionID)/timeline?scope=\(scope.rawValue)")
    }
    return try await get("/v1/sessions/\(sessionID)/timeline")
  }

  public func shutdown() async {
    session.invalidateAndCancel()
  }

  public func globalStream() async -> DaemonPushEventStream {
    stream("/v1/stream")
  }

  public func sessionStream(sessionID: String) async -> DaemonPushEventStream {
    stream("/v1/sessions/\(sessionID)/stream")
  }

  public func createTask(
    sessionID: String,
    request: TaskCreateRequest
  ) async throws -> SessionDetail {
    try await post("/v1/sessions/\(sessionID)/task", body: request)
  }

  public func assignTask(
    sessionID: String,
    taskID: String,
    request: TaskAssignRequest
  ) async throws -> SessionDetail {
    try await post("/v1/sessions/\(sessionID)/tasks/\(taskID)/assign", body: request)
  }

  public func dropTask(
    sessionID: String,
    taskID: String,
    request: TaskDropRequest
  ) async throws -> SessionDetail {
    try await post("/v1/sessions/\(sessionID)/tasks/\(taskID)/drop", body: request)
  }

  public func updateTaskQueuePolicy(
    sessionID: String,
    taskID: String,
    request: TaskQueuePolicyRequest
  ) async throws -> SessionDetail {
    try await post("/v1/sessions/\(sessionID)/tasks/\(taskID)/queue-policy", body: request)
  }

  public func updateTask(
    sessionID: String,
    taskID: String,
    request: TaskUpdateRequest
  ) async throws -> SessionDetail {
    try await post("/v1/sessions/\(sessionID)/tasks/\(taskID)/status", body: request)
  }

  public func checkpointTask(
    sessionID: String,
    taskID: String,
    request: TaskCheckpointRequest
  ) async throws -> SessionDetail {
    try await post("/v1/sessions/\(sessionID)/tasks/\(taskID)/checkpoint", body: request)
  }

  public func changeRole(
    sessionID: String,
    agentID: String,
    request: RoleChangeRequest
  ) async throws -> SessionDetail {
    try await post("/v1/sessions/\(sessionID)/agents/\(agentID)/role", body: request)
  }

  public func removeAgent(
    sessionID: String,
    agentID: String,
    request: AgentRemoveRequest
  ) async throws -> SessionDetail {
    try await post("/v1/sessions/\(sessionID)/agents/\(agentID)/remove", body: request)
  }

  public func transferLeader(
    sessionID: String,
    request: LeaderTransferRequest
  ) async throws -> SessionDetail {
    try await post("/v1/sessions/\(sessionID)/leader", body: request)
  }

  public func endSession(
    sessionID: String,
    request: SessionEndRequest
  ) async throws -> SessionDetail {
    try await post("/v1/sessions/\(sessionID)/end", body: request)
  }

  public func sendSignal(
    sessionID: String,
    request: SignalSendRequest
  ) async throws -> SessionDetail {
    try await post("/v1/sessions/\(sessionID)/signal", body: request)
  }

  public func cancelSignal(
    sessionID: String,
    request: SignalCancelRequest
  ) async throws -> SessionDetail {
    try await post("/v1/sessions/\(sessionID)/signal-cancel", body: request)
  }

  public func observeSession(
    sessionID: String,
    request: ObserveSessionRequest
  ) async throws -> SessionDetail {
    try await post("/v1/sessions/\(sessionID)/observe", body: request)
  }

  public func managedAgents(sessionID: String) async throws -> ManagedAgentListResponse {
    try await get("/v1/sessions/\(sessionID)/managed-agents")
  }

  public func managedAgent(agentID: String) async throws -> ManagedAgentSnapshot {
    try await get("/v1/managed-agents/\(agentID)")
  }

  public func startManagedTerminalAgent(
    sessionID: String,
    request: AgentTuiStartRequest
  ) async throws -> ManagedAgentSnapshot {
    try await post("/v1/sessions/\(sessionID)/managed-agents/terminal", body: request)
  }

  public func startManagedCodexAgent(
    sessionID: String,
    request: CodexRunRequest
  ) async throws -> ManagedAgentSnapshot {
    try await post("/v1/sessions/\(sessionID)/managed-agents/codex", body: request)
  }

  public func sendManagedAgentInput(
    agentID: String,
    request: AgentTuiInputRequest
  ) async throws -> ManagedAgentSnapshot {
    try await post("/v1/managed-agents/\(agentID)/input", body: request)
  }

  public func resizeManagedAgent(
    agentID: String,
    request: AgentTuiResizeRequest
  ) async throws -> ManagedAgentSnapshot {
    try await post("/v1/managed-agents/\(agentID)/resize", body: request)
  }

  public func stopManagedAgent(agentID: String) async throws -> ManagedAgentSnapshot {
    try await post("/v1/managed-agents/\(agentID)/stop", body: EmptyBody())
  }

  public func steerManagedCodexAgent(
    agentID: String,
    request: CodexSteerRequest
  ) async throws -> ManagedAgentSnapshot {
    try await post("/v1/managed-agents/\(agentID)/steer", body: request)
  }

  public func interruptManagedCodexAgent(agentID: String) async throws -> ManagedAgentSnapshot {
    try await post("/v1/managed-agents/\(agentID)/interrupt", body: EmptyBody())
  }

  public func resolveManagedCodexApproval(
    agentID: String,
    approvalID: String,
    request: CodexApprovalDecisionRequest
  ) async throws -> ManagedAgentSnapshot {
    try await post("/v1/managed-agents/\(agentID)/approvals/\(approvalID)", body: request)
  }

  public func codexRuns(sessionID: String) async throws -> CodexRunListResponse {
    let agents = try await managedAgents(sessionID: sessionID)
    return CodexRunListResponse(runs: agents.agents.compactMap { $0.codex })
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
    sessionID: String,
    request: VoiceSessionStartRequest
  ) async throws -> VoiceSessionStartResponse {
    try await post("/v1/sessions/\(sessionID)/voice-sessions", body: request)
  }

  public func appendVoiceAudioChunk(
    voiceSessionID: String,
    request: VoiceAudioChunkRequest
  ) async throws -> VoiceSessionMutationResponse {
    try await post("/v1/voice-sessions/\(voiceSessionID)/audio", body: request)
  }

  public func appendVoiceTranscript(
    voiceSessionID: String,
    request: VoiceTranscriptUpdateRequest
  ) async throws -> VoiceSessionMutationResponse {
    try await post("/v1/voice-sessions/\(voiceSessionID)/transcript", body: request)
  }

  public func finishVoiceSession(
    voiceSessionID: String,
    request: VoiceSessionFinishRequest
  ) async throws -> VoiceSessionMutationResponse {
    try await post("/v1/voice-sessions/\(voiceSessionID)/finish", body: request)
  }

  public func logLevel() async throws -> LogLevelResponse {
    try await get("/v1/daemon/log-level")
  }

  public func setLogLevel(_ level: String) async throws -> LogLevelResponse {
    try await put("/v1/daemon/log-level", body: SetLogLevelRequest(level: level))
  }
}
