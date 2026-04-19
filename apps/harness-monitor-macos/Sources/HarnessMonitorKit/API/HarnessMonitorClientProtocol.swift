import Foundation

public typealias DaemonPushEventStream = AsyncThrowingStream<DaemonPushEvent, Error>
public typealias TimelineBatchHandler =
  @Sendable (_ entries: [TimelineEntry], _ batchIndex: Int, _ batchCount: Int) async -> Void
public typealias TimelineWindowBatchHandler =
  @Sendable (_ response: TimelineWindowResponse, _ batchIndex: Int, _ batchCount: Int) async -> Void

public enum TimelineScope: String, Codable, Equatable, Sendable {
  case full
  case summary
}

public protocol HarnessMonitorClientProtocol: Sendable {
  func health() async throws -> HealthResponse
  func transportLatencyMs() async throws -> Int?
  func shutdown() async
  func diagnostics() async throws -> DaemonDiagnosticsReport
  func stopDaemon() async throws -> DaemonControlResponse
  func reconfigureHostBridge(
    request: HostBridgeReconfigureRequest
  ) async throws -> BridgeStatusReport
  func projects() async throws -> [ProjectSummary]
  func sessions() async throws -> [SessionSummary]
  func sessionDetail(id: String, scope: String?) async throws -> SessionDetail
  func timelineWindow(sessionID: String, request: TimelineWindowRequest) async throws
    -> TimelineWindowResponse
  func timelineWindow(
    sessionID: String,
    request: TimelineWindowRequest,
    onBatch: @escaping TimelineWindowBatchHandler
  ) async throws -> TimelineWindowResponse
  func timeline(sessionID: String) async throws -> [TimelineEntry]
  func timeline(
    sessionID: String,
    onBatch: @escaping TimelineBatchHandler
  ) async throws -> [TimelineEntry]
  func timeline(sessionID: String, scope: TimelineScope) async throws -> [TimelineEntry]
  func timeline(
    sessionID: String,
    scope: TimelineScope,
    onBatch: @escaping TimelineBatchHandler
  ) async throws -> [TimelineEntry]
  func globalStream() async -> DaemonPushEventStream
  func sessionStream(sessionID: String) async -> DaemonPushEventStream
  func createTask(sessionID: String, request: TaskCreateRequest) async throws -> SessionDetail
  func assignTask(
    sessionID: String,
    taskID: String,
    request: TaskAssignRequest
  ) async throws -> SessionDetail
  func dropTask(
    sessionID: String,
    taskID: String,
    request: TaskDropRequest
  ) async throws -> SessionDetail
  func updateTaskQueuePolicy(
    sessionID: String,
    taskID: String,
    request: TaskQueuePolicyRequest
  ) async throws -> SessionDetail
  func updateTask(
    sessionID: String,
    taskID: String,
    request: TaskUpdateRequest
  ) async throws -> SessionDetail
  func checkpointTask(
    sessionID: String,
    taskID: String,
    request: TaskCheckpointRequest
  ) async throws -> SessionDetail
  func changeRole(
    sessionID: String,
    agentID: String,
    request: RoleChangeRequest
  ) async throws -> SessionDetail
  func removeAgent(
    sessionID: String,
    agentID: String,
    request: AgentRemoveRequest
  ) async throws -> SessionDetail
  func transferLeader(
    sessionID: String,
    request: LeaderTransferRequest
  ) async throws -> SessionDetail
  func endSession(
    sessionID: String,
    request: SessionEndRequest
  ) async throws -> SessionDetail
  func sendSignal(
    sessionID: String,
    request: SignalSendRequest
  ) async throws -> SessionDetail
  func cancelSignal(
    sessionID: String,
    request: SignalCancelRequest
  ) async throws -> SessionDetail
  func observeSession(
    sessionID: String,
    request: ObserveSessionRequest
  ) async throws -> SessionDetail
  func managedAgents(sessionID: String) async throws -> ManagedAgentListResponse
  func managedAgent(agentID: String) async throws -> ManagedAgentSnapshot
  func startManagedTerminalAgent(
    sessionID: String,
    request: AgentTuiStartRequest
  ) async throws -> ManagedAgentSnapshot
  func startManagedCodexAgent(
    sessionID: String,
    request: CodexRunRequest
  ) async throws -> ManagedAgentSnapshot
  func sendManagedAgentInput(
    agentID: String,
    request: AgentTuiInputRequest
  ) async throws -> ManagedAgentSnapshot
  func resizeManagedAgent(
    agentID: String,
    request: AgentTuiResizeRequest
  ) async throws -> ManagedAgentSnapshot
  func stopManagedAgent(agentID: String) async throws -> ManagedAgentSnapshot
  func steerManagedCodexAgent(
    agentID: String,
    request: CodexSteerRequest
  ) async throws -> ManagedAgentSnapshot
  func interruptManagedCodexAgent(agentID: String) async throws -> ManagedAgentSnapshot
  func resolveManagedCodexApproval(
    agentID: String,
    approvalID: String,
    request: CodexApprovalDecisionRequest
  ) async throws -> ManagedAgentSnapshot
  func codexRuns(sessionID: String) async throws -> CodexRunListResponse
  func codexRun(runID: String) async throws -> CodexRunSnapshot
  func startCodexRun(
    sessionID: String,
    request: CodexRunRequest
  ) async throws -> CodexRunSnapshot
  func steerCodexRun(
    runID: String,
    request: CodexSteerRequest
  ) async throws -> CodexRunSnapshot
  func interruptCodexRun(runID: String) async throws -> CodexRunSnapshot
  func resolveCodexApproval(
    runID: String,
    approvalID: String,
    request: CodexApprovalDecisionRequest
  ) async throws -> CodexRunSnapshot
  func agentTuis(sessionID: String) async throws -> AgentTuiListResponse
  func agentTui(tuiID: String) async throws -> AgentTuiSnapshot
  func startAgentTui(
    sessionID: String,
    request: AgentTuiStartRequest
  ) async throws -> AgentTuiSnapshot
  func sendAgentTuiInput(
    tuiID: String,
    request: AgentTuiInputRequest
  ) async throws -> AgentTuiSnapshot
  func resizeAgentTui(
    tuiID: String,
    request: AgentTuiResizeRequest
  ) async throws -> AgentTuiSnapshot
  func stopAgentTui(tuiID: String) async throws -> AgentTuiSnapshot
  func startVoiceSession(
    sessionID: String,
    request: VoiceSessionStartRequest
  ) async throws -> VoiceSessionStartResponse
  func appendVoiceAudioChunk(
    voiceSessionID: String,
    request: VoiceAudioChunkRequest
  ) async throws -> VoiceSessionMutationResponse
  func appendVoiceTranscript(
    voiceSessionID: String,
    request: VoiceTranscriptUpdateRequest
  ) async throws -> VoiceSessionMutationResponse
  func finishVoiceSession(
    voiceSessionID: String,
    request: VoiceSessionFinishRequest
  ) async throws -> VoiceSessionMutationResponse
  func personas() async throws -> [AgentPersona]
  func runtimeModelCatalogs() async throws -> [RuntimeModelCatalog]
  func configuration() async throws -> MonitorConfiguration
  func logLevel() async throws -> LogLevelResponse
  func setLogLevel(_ level: String) async throws -> LogLevelResponse
}

extension HarnessMonitorClientProtocol {
  public func transportLatencyMs() async throws -> Int? {
    nil
  }

  public func shutdown() async {}

  public func reconfigureHostBridge(
    request _: HostBridgeReconfigureRequest
  ) async throws -> BridgeStatusReport {
    throw HarnessMonitorAPIError.server(code: 501, message: "Host bridge unavailable.")
  }

  public func sessionDetail(id: String) async throws -> SessionDetail {
    try await sessionDetail(id: id, scope: nil)
  }

  public func timelineWindow(sessionID: String, request: TimelineWindowRequest) async throws
    -> TimelineWindowResponse
  {
    try await timelineWindow(sessionID: sessionID, request: request) { _, _, _ in }
  }

  public func timelineWindow(
    sessionID: String,
    request: TimelineWindowRequest,
    onBatch: @escaping TimelineWindowBatchHandler
  ) async throws -> TimelineWindowResponse {
    let resolvedScope = request.scope ?? .full
    let entries = try await timeline(
      sessionID: sessionID,
      scope: resolvedScope
    ) { entries, batchIndex, batchCount in
      let response = timelineWindowResponse(
        from: entries,
        request: request
      )
      await onBatch(response, batchIndex, batchCount)
    }
    return timelineWindowResponse(
      from: entries,
      request: request
    )
  }

  public func timeline(
    sessionID: String,
    onBatch: @escaping TimelineBatchHandler
  ) async throws -> [TimelineEntry] {
    let entries = try await timeline(sessionID: sessionID)
    await onBatch(entries, 0, 1)
    return entries
  }

  public func timeline(sessionID: String, scope _: TimelineScope) async throws -> [TimelineEntry] {
    try await timeline(sessionID: sessionID)
  }

  public func timeline(
    sessionID: String,
    scope: TimelineScope,
    onBatch: @escaping TimelineBatchHandler
  ) async throws -> [TimelineEntry] {
    let entries = try await timeline(sessionID: sessionID, scope: scope)
    await onBatch(entries, 0, 1)
    return entries
  }

  public func personas() async throws -> [AgentPersona] {
    []
  }

  public func runtimeModelCatalogs() async throws -> [RuntimeModelCatalog] {
    []
  }

  public func configuration() async throws -> MonitorConfiguration {
    MonitorConfiguration(personas: [], runtimeModels: [])
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

  private func timelineWindowResponse(
    from entries: [TimelineEntry],
    request: TimelineWindowRequest
  ) -> TimelineWindowResponse {
    let oldestCursor = entries.first.map {
      TimelineCursor(recordedAt: $0.recordedAt, entryId: $0.entryId)
    }
    let newestCursor = entries.last.map {
      TimelineCursor(recordedAt: $0.recordedAt, entryId: $0.entryId)
    }
    let totalCount = entries.count
    let windowCount = entries.count
    let windowStart = max(0, totalCount - windowCount)
    return TimelineWindowResponse(
      revision: request.knownRevision ?? 0,
      totalCount: totalCount,
      windowStart: windowStart,
      windowEnd: totalCount,
      hasOlder: false,
      hasNewer: false,
      oldestCursor: oldestCursor,
      newestCursor: newestCursor,
      entries: entries,
      unchanged: false
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
      throw HarnessMonitorAPIError.server(code: 500, message: "Managed Codex agent did not return a Codex snapshot.")
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

public struct HarnessMonitorConnection: Equatable, Sendable {
  public let endpoint: URL
  public let token: String

  public init(endpoint: URL, token: String) {
    self.endpoint = endpoint
    self.token = token
  }
}

public enum HarnessMonitorAPIError: Error, LocalizedError, Equatable {
  case invalidEndpoint(String)
  case invalidResponse
  case server(code: Int, message: String)

  public var errorDescription: String? {
    switch self {
    case .invalidEndpoint(let value):
      "Invalid daemon endpoint: \(value)"
    case .invalidResponse:
      "The daemon returned an invalid response."
    case .server(let code, let message):
      "Daemon error \(code): \(message)"
    }
  }
}
