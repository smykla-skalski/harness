import Foundation

public typealias DaemonPushEventStream = AsyncThrowingStream<DaemonPushEvent, Error>

public protocol HarnessMonitorClientProtocol: Sendable {
  func health() async throws -> HealthResponse
  func transportLatencyMs() async throws -> Int?
  func shutdown() async
  func diagnostics() async throws -> DaemonDiagnosticsReport
  func stopDaemon() async throws -> DaemonControlResponse
  func projects() async throws -> [ProjectSummary]
  func sessions() async throws -> [SessionSummary]
  func sessionDetail(id: String, scope: String?) async throws -> SessionDetail
  func timeline(sessionID: String) async throws -> [TimelineEntry]
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
  func logLevel() async throws -> LogLevelResponse
  func setLogLevel(_ level: String) async throws -> LogLevelResponse
}

extension HarnessMonitorClientProtocol {
  public func transportLatencyMs() async throws -> Int? {
    nil
  }

  public func shutdown() async {}

  public func sessionDetail(id: String) async throws -> SessionDetail {
    try await sessionDetail(id: id, scope: nil)
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
