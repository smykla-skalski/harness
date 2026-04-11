import Foundation

public final class HarnessMonitorAPIClient: HarnessMonitorClientProtocol {
  private static let requestTimeoutInterval: TimeInterval = 15
  private static let resourceTimeoutInterval: TimeInterval = 30

  private let connection: HarnessMonitorConnection
  private let decoder: JSONDecoder
  private let encoder: JSONEncoder
  private let session: URLSession

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
    try await get("/v1/sessions/\(sessionID)/timeline")
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

  public func codexRuns(sessionID: String) async throws -> CodexRunListResponse {
    try await get("/v1/sessions/\(sessionID)/codex-runs")
  }

  public func codexRun(runID: String) async throws -> CodexRunSnapshot {
    try await get("/v1/codex-runs/\(runID)")
  }

  public func startCodexRun(
    sessionID: String,
    request: CodexRunRequest
  ) async throws -> CodexRunSnapshot {
    try await post("/v1/sessions/\(sessionID)/codex-runs", body: request)
  }

  public func steerCodexRun(
    runID: String,
    request: CodexSteerRequest
  ) async throws -> CodexRunSnapshot {
    try await post("/v1/codex-runs/\(runID)/steer", body: request)
  }

  public func interruptCodexRun(runID: String) async throws -> CodexRunSnapshot {
    try await post("/v1/codex-runs/\(runID)/interrupt", body: EmptyBody())
  }

  public func resolveCodexApproval(
    runID: String,
    approvalID: String,
    request: CodexApprovalDecisionRequest
  ) async throws -> CodexRunSnapshot {
    try await post("/v1/codex-runs/\(runID)/approvals/\(approvalID)", body: request)
  }

  public func agentTuis(sessionID: String) async throws -> AgentTuiListResponse {
    try await get("/v1/sessions/\(sessionID)/agent-tuis")
  }

  public func agentTui(tuiID: String) async throws -> AgentTuiSnapshot {
    try await get("/v1/agent-tuis/\(tuiID)")
  }

  public func startAgentTui(
    sessionID: String,
    request: AgentTuiStartRequest
  ) async throws -> AgentTuiSnapshot {
    try await post("/v1/sessions/\(sessionID)/agent-tuis", body: request)
  }

  public func sendAgentTuiInput(
    tuiID: String,
    request: AgentTuiInputRequest
  ) async throws -> AgentTuiSnapshot {
    try await post("/v1/agent-tuis/\(tuiID)/input", body: request)
  }

  public func resizeAgentTui(
    tuiID: String,
    request: AgentTuiResizeRequest
  ) async throws -> AgentTuiSnapshot {
    try await post("/v1/agent-tuis/\(tuiID)/resize", body: request)
  }

  public func stopAgentTui(tuiID: String) async throws -> AgentTuiSnapshot {
    try await post("/v1/agent-tuis/\(tuiID)/stop", body: EmptyBody())
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

  private func get<Response: Decodable>(_ path: String) async throws -> Response {
    var request = try makeRequest(path: path)
    request.httpMethod = "GET"
    return try await send(request)
  }

  private func post<RequestBody: Encodable, Response: Decodable>(
    _ path: String,
    body: RequestBody
  ) async throws -> Response {
    var request = try makeRequest(path: path)
    request.httpMethod = "POST"
    request.httpBody = try encoder.encode(AnyEncodable(body))
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return try await send(request)
  }

  private func put<RequestBody: Encodable, Response: Decodable>(
    _ path: String,
    body: RequestBody
  ) async throws -> Response {
    var request = try makeRequest(path: path)
    request.httpMethod = "PUT"
    request.httpBody = try encoder.encode(AnyEncodable(body))
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return try await send(request)
  }

  private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
    let start = ContinuousClock.now
    let (data, response) = try await session.data(for: request)
    let elapsed = start.duration(to: .now)
    let durationMs =
      elapsed.components.seconds * 1000
      + Int64(elapsed.components.attoseconds / 1_000_000_000_000_000)
    let method = request.httpMethod ?? "?"
    let path = request.url?.path ?? "?"
    guard let httpResponse = response as? HTTPURLResponse else {
      HarnessMonitorLogger.api.error(
        "Invalid response for \(method, privacy: .public) \(path, privacy: .public)"
      )
      throw HarnessMonitorAPIError.invalidResponse
    }

    HarnessMonitorLogger.api.debug(
      "\(method, privacy: .public) \(path, privacy: .public) -> \(httpResponse.statusCode) (\(durationMs)ms)"
    )

    guard (200..<300).contains(httpResponse.statusCode) else {
      throw try decodeError(statusCode: httpResponse.statusCode, data: data)
    }

    return try decoder.decode(Response.self, from: data)
  }

  private func stream(_ path: String) -> DaemonPushEventStream {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let request = try makeRequest(path: path)
          let (bytes, response) = try await session.bytes(for: request)
          guard let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
          else {
            throw HarnessMonitorAPIError.invalidResponse
          }

          var parser = ServerSentEventParser()
          for try await line in bytes.lines {
            if let frame = parser.push(line: line) {
              let event = try decoder.decode(
                StreamEvent.self,
                from: Data(frame.data.utf8)
              )
              continuation.yield(try DaemonPushEvent(streamEvent: event))
            }
          }

          if let frame = parser.finish() {
            let event = try decoder.decode(StreamEvent.self, from: Data(frame.data.utf8))
            continuation.yield(try DaemonPushEvent(streamEvent: event))
          }

          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  private func makeRequest(path: String) throws -> URLRequest {
    guard let url = URL(string: path, relativeTo: connection.endpoint) else {
      throw HarnessMonitorAPIError.invalidEndpoint(connection.endpoint.absoluteString)
    }

    var request = URLRequest(url: url)
    request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return request
  }

  private func decodeError(statusCode: Int, data: Data) throws -> HarnessMonitorAPIError {
    if let envelope = try? decoder.decode(ErrorEnvelope.self, from: data) {
      return .server(code: statusCode, message: envelope.error.message)
    }

    if let envelope = try? decoder.decode(FlatErrorEnvelope.self, from: data) {
      var parts = [envelope.error]
      if let feature = envelope.feature, !feature.isEmpty {
        parts.append(feature)
      }
      if let endpoint = envelope.endpoint, !endpoint.isEmpty {
        parts.append(endpoint)
      }
      if let hint = envelope.hint, !hint.isEmpty {
        parts.append(hint)
      }
      return .server(code: statusCode, message: parts.joined(separator: " - "))
    }

    let message = String(data: data, encoding: .utf8) ?? "Unknown daemon error"
    return .server(code: statusCode, message: message)
  }
}

private struct EmptyBody: Encodable {}

private struct AnyEncodable: Encodable {
  private let encodeClosure: (Encoder) throws -> Void

  init<Value: Encodable>(_ value: Value) {
    encodeClosure = value.encode(to:)
  }

  func encode(to encoder: Encoder) throws {
    try encodeClosure(encoder)
  }
}

private struct FlatErrorEnvelope: Decodable {
  let error: String
  let feature: String?
  let endpoint: String?
  let hint: String?
}
