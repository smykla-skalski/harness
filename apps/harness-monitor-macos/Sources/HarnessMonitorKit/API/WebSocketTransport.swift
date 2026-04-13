import Foundation

private final class SemanticBatchDeliveryTracker: @unchecked Sendable {
  var delivered = false
}

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
  var sessionStreamContinuations:
    [String: AsyncThrowingStream<DaemonPushEvent, Error>.Continuation] = [:]
  var responseBatchHandlers: [String: ResponseBatchHandler] = [:]
  var partialFrames: [String: PendingFrameChunks] = [:]
  var activeSubscriptions: Set<String> = []
  var globalSubscriptionActive = false
  var isShutDown = false

  static let reconnectDelays: [Duration] = [
    .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8),
  ]

  public init(connection: HarnessMonitorConnection) {
    self.connection = connection
    encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    // WebSocket sessions must not have a resource timeout - the 30s
    // default kills long-lived connections. Request timeout covers
    // individual frame sends; heartbeat handles liveness detection.
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 0
    session = URLSession(configuration: configuration)

    let httpConfiguration = URLSessionConfiguration.default
    httpConfiguration.timeoutIntervalForRequest = 15
    httpConfiguration.timeoutIntervalForResource = 30
    let httpSession = URLSession(configuration: httpConfiguration)
    httpFallbackClient = HarnessMonitorAPIClient(
      connection: connection,
      session: httpSession
    )
  }

  public func connect() async throws {
    guard !isShutDown else {
      throw WebSocketTransportError.connectionClosed
    }
    let wsURL = wsEndpoint()
    HarnessMonitorLogger.websocket.info(
      "WebSocket connecting to \(wsURL.absoluteString, privacy: .public)")
    var request = URLRequest(url: wsURL)
    request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
    let task = session.webSocketTask(with: request)
    webSocketTask = task
    task.resume()
    startReceiveLoop()
    startHeartbeat()
  }

  public func disconnect() {
    HarnessMonitorLogger.websocket.info("WebSocket disconnected")
    receiveTask?.cancel()
    heartbeatTask?.cancel()
    cancelWebSocketTaskIfNeeded(closeCode: .normalClosure)
    webSocketTask = nil
    responseBatchHandlers.removeAll()
    partialFrames.removeAll()
    pending.failAll(error: WebSocketTransportError.connectionClosed)
    terminateAllStreams()
  }

  public func shutdown() async {
    isShutDown = true
    disconnect()
    session.invalidateAndCancel()
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

  public func reconfigureHostBridge(
    request: HostBridgeReconfigureRequest
  ) async throws -> BridgeStatusReport {
    try await httpFallbackClient.reconfigureHostBridge(request: request)
  }

  public func projects() async throws -> [ProjectSummary] {
    let value = try await send(method: "projects")
    return try decode(value)
  }

  public func sessions() async throws -> [SessionSummary] {
    let value = try await send(method: "sessions")
    return try decode(value)
  }

  public func sessionDetail(id: String, scope: String?) async throws -> SessionDetail {
    var params: [String: JSONValue] = ["session_id": .string(id)]
    if let scope {
      params["scope"] = .string(scope)
    }
    let value = try await send(method: "session.detail", params: .object(params))
    return try decode(value)
  }

  public func timeline(sessionID: String) async throws -> [TimelineEntry] {
    try await timeline(sessionID: sessionID) { _, _, _ in }
  }

  public func timeline(
    sessionID: String,
    onBatch: @escaping TimelineBatchHandler
  ) async throws -> [TimelineEntry] {
    let params: [String: JSONValue] = ["session_id": .string(sessionID)]
    let deliveryTracker = SemanticBatchDeliveryTracker()
    let value = try await send(
      method: "session.timeline",
      params: .object(params),
      onSemanticBatch: { [weak self] batchIndex, batchCount, result in
        guard let self else { return }
        let entries: [TimelineEntry] = try self.decode(result ?? .array([]))
        deliveryTracker.delivered = true
        await onBatch(entries, batchIndex, batchCount)
      }
    )
    let entries: [TimelineEntry] = try decode(value)
    if deliveryTracker.delivered == false {
      await onBatch(entries, 0, 1)
    }
    return entries
  }
}

extension WebSocketTransport {
  // MARK: - Streams

  public func globalStream() async -> DaemonPushEventStream {
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

  public func sessionStream(sessionID: String) async -> DaemonPushEventStream {
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
    try await httpFallbackClient.agentTuis(sessionID: sessionID)
  }

  public func agentTui(tuiID: String) async throws -> AgentTuiSnapshot {
    try await httpFallbackClient.agentTui(tuiID: tuiID)
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
