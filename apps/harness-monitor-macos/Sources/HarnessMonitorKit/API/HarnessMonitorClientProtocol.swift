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

  public func codexRuns(sessionID _: String) async throws -> CodexRunListResponse {
    CodexRunListResponse(runs: [])
  }

  public func codexRun(runID _: String) async throws -> CodexRunSnapshot {
    throw HarnessMonitorAPIError.server(code: 404, message: "Codex run unavailable.")
  }

  public func startCodexRun(
    sessionID _: String,
    request _: CodexRunRequest
  ) async throws -> CodexRunSnapshot {
    throw HarnessMonitorAPIError.server(code: 501, message: "Codex controller unavailable.")
  }

  public func steerCodexRun(
    runID _: String,
    request _: CodexSteerRequest
  ) async throws -> CodexRunSnapshot {
    throw HarnessMonitorAPIError.server(code: 501, message: "Codex controller unavailable.")
  }

  public func interruptCodexRun(runID _: String) async throws -> CodexRunSnapshot {
    throw HarnessMonitorAPIError.server(code: 501, message: "Codex controller unavailable.")
  }

  public func resolveCodexApproval(
    runID _: String,
    approvalID _: String,
    request _: CodexApprovalDecisionRequest
  ) async throws -> CodexRunSnapshot {
    throw HarnessMonitorAPIError.server(code: 501, message: "Codex controller unavailable.")
  }

  public func agentTuis(sessionID _: String) async throws -> AgentTuiListResponse {
    AgentTuiListResponse(tuis: [])
  }

  public func agentTui(tuiID _: String) async throws -> AgentTuiSnapshot {
    throw HarnessMonitorAPIError.server(code: 404, message: "Agent TUI unavailable.")
  }

  public func startAgentTui(
    sessionID _: String,
    request _: AgentTuiStartRequest
  ) async throws -> AgentTuiSnapshot {
    throw HarnessMonitorAPIError.server(code: 501, message: "Agent TUI unavailable.")
  }

  public func sendAgentTuiInput(
    tuiID _: String,
    request _: AgentTuiInputRequest
  ) async throws -> AgentTuiSnapshot {
    throw HarnessMonitorAPIError.server(code: 501, message: "Agent TUI unavailable.")
  }

  public func resizeAgentTui(
    tuiID _: String,
    request _: AgentTuiResizeRequest
  ) async throws -> AgentTuiSnapshot {
    throw HarnessMonitorAPIError.server(code: 501, message: "Agent TUI unavailable.")
  }

  public func stopAgentTui(tuiID _: String) async throws -> AgentTuiSnapshot {
    throw HarnessMonitorAPIError.server(code: 501, message: "Agent TUI unavailable.")
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
