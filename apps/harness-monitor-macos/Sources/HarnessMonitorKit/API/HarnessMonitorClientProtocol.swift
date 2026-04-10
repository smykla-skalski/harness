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
