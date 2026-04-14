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
    try await timeline(sessionID: sessionID, scope: .full) { _, _, _ in }
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
    let value = try await send(
      method: "session.timeline",
      params: timelineWindowParams(sessionID: sessionID, request: request)
    )
    let response: TimelineWindowResponse = try decode(value)
    await onBatch(response, 0, 1)
    return response
  }

  public func timeline(
    sessionID: String,
    onBatch: @escaping TimelineBatchHandler
  ) async throws -> [TimelineEntry] {
    try await timeline(sessionID: sessionID, scope: .full, onBatch: onBatch)
  }

  public func timeline(sessionID: String, scope: TimelineScope) async throws -> [TimelineEntry] {
    try await timeline(sessionID: sessionID, scope: scope) { _, _, _ in }
  }

  public func timeline(
    sessionID: String,
    scope: TimelineScope,
    onBatch: @escaping TimelineBatchHandler
  ) async throws -> [TimelineEntry] {
    var params: [String: JSONValue] = ["session_id": .string(sessionID)]
    if scope == .summary {
      params["scope"] = .string(scope.rawValue)
    }
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

  private func timelineWindowParams(
    sessionID: String,
    request: TimelineWindowRequest
  ) -> JSONValue {
    var params: [String: JSONValue] = ["session_id": .string(sessionID)]
    if let scope = request.scope?.rawValue {
      params["scope"] = .string(scope)
    }
    if let limit = request.limit {
      params["limit"] = .number(Double(limit))
    }
    if let knownRevision = request.knownRevision {
      params["known_revision"] = .number(Double(knownRevision))
    }
    if let before = request.before {
      params["before"] = .object([
        "recorded_at": .string(before.recordedAt),
        "entry_id": .string(before.entryId),
      ])
    }
    if let after = request.after {
      params["after"] = .object([
        "recorded_at": .string(after.recordedAt),
        "entry_id": .string(after.entryId),
      ])
    }
    return .object(params)
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
