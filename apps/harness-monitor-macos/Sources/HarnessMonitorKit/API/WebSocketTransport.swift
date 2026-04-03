import Foundation

public actor WebSocketTransport: HarnessMonitorClientProtocol {
  let connection: HarnessMonitorConnection
  let encoder: JSONEncoder
  let decoder: JSONDecoder
  let session: URLSession
  let httpFallbackClient: HarnessMonitorAPIClient
  let pending = PendingRequestStore()
  var webSocketTask: URLSessionWebSocketTask?
  var receiveTask: Task<Void, Never>?
  var heartbeatTask: Task<Void, Never>?
  var globalStreamContinuation: AsyncThrowingStream<DaemonPushEvent, Error>.Continuation?
  var sessionStreamContinuations: [
    String: AsyncThrowingStream<DaemonPushEvent, Error>.Continuation
  ] = [:]
  var activeSubscriptions: Set<String> = []
  var globalSubscriptionActive = false

  static let reconnectDelays: [Duration] = [
    .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8),
  ]

  public init(connection: HarnessMonitorConnection) {
    self.connection = connection
    encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    session = URLSession(configuration: .default)
    httpFallbackClient = HarnessMonitorAPIClient(
      connection: connection,
      session: session
    )
  }

  public func connect() async throws {
    let wsURL = wsEndpoint()
    var request = URLRequest(url: wsURL)
    request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
    let task = session.webSocketTask(with: request)
    webSocketTask = task
    task.resume()
    startReceiveLoop()
    startHeartbeat()
  }

  public func disconnect() {
    receiveTask?.cancel()
    heartbeatTask?.cancel()
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    webSocketTask = nil
    pending.failAll(error: WebSocketTransportError.connectionClosed)
    terminateAllStreams()
  }
}

extension WebSocketTransport {
  // MARK: - HarnessMonitorClientProtocol queries

  public func transportLatencyMs() async throws -> Int? {
    try await pingLatencyMs()
  }

  public func health() async throws -> HealthResponse {
    let value = try await send(method: "health")
    return try decode(value)
  }

  public func diagnostics() async throws -> DaemonDiagnosticsReport {
    let value = try await send(method: "diagnostics")
    return try decode(value)
  }

  public func stopDaemon() async throws -> DaemonControlResponse {
    let value = try await send(method: "daemon.stop")
    return try decode(value)
  }

  public func projects() async throws -> [ProjectSummary] {
    let value = try await send(method: "projects")
    return try decode(value)
  }

  public func sessions() async throws -> [SessionSummary] {
    let value = try await send(method: "sessions")
    return try decode(value)
  }

  public func sessionDetail(id: String) async throws -> SessionDetail {
    try await httpFallbackClient.sessionDetail(id: id)
  }

  public func timeline(sessionID: String) async throws -> [TimelineEntry] {
    try await httpFallbackClient.timeline(sessionID: sessionID)
  }
}

extension WebSocketTransport {
  // MARK: - Streams

  public func globalStream() async -> AsyncThrowingStream<DaemonPushEvent, Error> {
    let (stream, continuation) = AsyncThrowingStream<DaemonPushEvent, Error>.makeStream()
    globalStreamContinuation = continuation
    globalSubscriptionActive = true

    continuation.onTermination = { [weak self] _ in
      guard let self else { return }
      Task { await self.cleanupGlobalSubscription() }
    }

    Task {
      do {
        _ = try await self.send(
          method: "stream.subscribe",
          params: .object(["scope": .string("global")])
        )
      } catch {
        continuation.finish(throwing: error)
      }
    }

    return stream
  }

  private func cleanupGlobalSubscription() {
    globalStreamContinuation = nil
    globalSubscriptionActive = false
    Task {
      try? await send(
        method: "stream.unsubscribe",
        params: .object(["scope": .string("global")])
      )
    }
  }

  public func sessionStream(sessionID: String) async -> AsyncThrowingStream<DaemonPushEvent, Error> {
    let (stream, continuation) = AsyncThrowingStream<DaemonPushEvent, Error>.makeStream()
    sessionStreamContinuations[sessionID] = continuation
    activeSubscriptions.insert(sessionID)

    continuation.onTermination = { [weak self] _ in
      guard let self else { return }
      Task { await self.cleanupSessionSubscription(sessionID: sessionID) }
    }

    Task {
      do {
        _ = try await self.send(
          method: "session.subscribe",
          params: .object(["session_id": .string(sessionID)])
        )
      } catch {
        continuation.finish(throwing: error)
      }
    }

    return stream
  }

  private func cleanupSessionSubscription(sessionID: String) {
    sessionStreamContinuations[sessionID] = nil
    activeSubscriptions.remove(sessionID)
    Task {
      try? await send(
        method: "session.unsubscribe",
        params: .object(["session_id": .string(sessionID)])
      )
    }
  }
}

extension WebSocketTransport {
  // MARK: - Mutations

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

  public func observeSession(
    sessionID: String,
    request: ObserveSessionRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(request, extra: ["session_id": .string(sessionID)])
    let value = try await send(method: "session.observe", params: params)
    return try decode(value)
  }
}
