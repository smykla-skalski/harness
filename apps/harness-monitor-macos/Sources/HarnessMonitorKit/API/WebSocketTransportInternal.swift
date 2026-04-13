import Foundation

// MARK: - Internal transport mechanics

private typealias VoidPingContinuation = CheckedContinuation<Void, Error>
private typealias IntPingContinuation = CheckedContinuation<Int, Error>
typealias ResponseBatchHandler =
  @Sendable (_ batchIndex: Int, _ batchCount: Int, _ result: JSONValue?) async throws -> Void

extension WebSocketTransport {
  func sendPing() async throws {
    guard let webSocketTask else {
      throw WebSocketTransportError.connectionClosed
    }
    let task = webSocketTask
    try await withCheckedThrowingContinuation { (continuation: VoidPingContinuation) in
      task.sendPing { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  func pingLatencyMs() async throws -> Int {
    guard let webSocketTask else {
      throw WebSocketTransportError.connectionClosed
    }
    let task = webSocketTask
    let startedAt = ContinuousClock.now
    return try await withCheckedThrowingContinuation { (continuation: IntPingContinuation) in
      task.sendPing { error in
        let duration = startedAt.duration(to: ContinuousClock.now)
        let ms =
          max(0, Int(duration.components.seconds * 1_000))
          + Int(duration.components.attoseconds / 1_000_000_000_000_000)
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: ms)
        }
      }
    }
  }

  @discardableResult
  func send(
    method: String,
    params: JSONValue? = nil,
    onSemanticBatch: ResponseBatchHandler? = nil
  ) async throws -> JSONValue {
    guard !isShutDown, let webSocketTask else {
      throw WebSocketTransportError.connectionClosed
    }
    let id = UUID().uuidString
    let request = WsRequest(id: id, method: method, params: params)
    let data = try encoder.encode(request)
    let text = String(data: data, encoding: .utf8) ?? "{}"
    let task = webSocketTask
    let store = pending
    if let onSemanticBatch {
      responseBatchHandlers[id] = onSemanticBatch
    }
    return try await withCheckedThrowingContinuation { continuation in
      store.register(id: id, continuation: continuation)
      task.send(.string(text)) { error in
        if let error {
          Task { await self.clearResponseBatchHandler(for: id) }
          store.fail(id: id, error: error)
        }
      }
    }
  }

  /// Maximum internal WS reconnection attempts before giving up and
  /// letting the store-level retry escalate to a full re-bootstrap
  /// (which re-reads the daemon manifest and discovers the new port).
  private static let maxReconnectAttempts = reconnectDelays.count

  func startReceiveLoop() {
    receiveTask?.cancel()
    receiveTask = Task { [weak self] in
      guard let self else { return }
      var attempt = 0
      while !Task.isCancelled {
        guard let webSocketTask = await self.webSocketTask else { break }
        do {
          let message = try await webSocketTask.receive()
          attempt = 0
          try await self.handleMessage(message)
        } catch {
          if Task.isCancelled { return }
          self.pending.failAll(error: error)
          await self.clearResponseBatchHandlers()
          await self.clearPartialFrames()
          await self.terminateAllStreams()
          if attempt >= Self.maxReconnectAttempts {
            HarnessMonitorLogger.websocket.warning(
              "WebSocket reconnection exhausted after \(attempt) attempts, yielding to store"
            )
            break
          }
          let delay = Self.reconnectDelays[
            min(attempt, Self.reconnectDelays.count - 1)
          ]
          attempt += 1
          try? await Task.sleep(for: delay)
          if Task.isCancelled { return }
          if await self.isShutDown { return }
          try? await self.reconnectInternal()
        }
      }
    }
  }

  func reconnectInternal() async throws {
    guard !isShutDown else {
      throw WebSocketTransportError.connectionClosed
    }
    HarnessMonitorLogger.websocket.info("WebSocket reconnecting")
    heartbeatTask?.cancel()
    // Error-recovery path: the existing socket is already dead (that's why
    // the receive loop threw). Drop it with a plain cancel so URLSession does
    // not try to write a close frame to a disconnected fd, which logs a
    // spurious `nw_socket_output_finished ... shutdown(21, SHUT_WR)` warning.
    webSocketTask?.cancel()
    webSocketTask = nil
    responseBatchHandlers.removeAll()
    partialFrames.removeAll()
    let wsURL = wsEndpoint()
    var request = URLRequest(url: wsURL)
    request.setValue(
      "Bearer \(connection.token)",
      forHTTPHeaderField: "Authorization"
    )
    let task = session.webSocketTask(with: request)
    webSocketTask = task
    task.resume()
    startHeartbeat()
    try await resubscribe()
  }

  func resubscribe() async throws {
    if globalSubscriptionActive {
      _ = try await send(
        method: "stream.subscribe",
        params: .object(["scope": .string("global")])
      )
    }
    for sessionID in activeSubscriptions {
      _ = try await send(
        method: "session.subscribe",
        params: .object(["session_id": .string(sessionID)])
      )
    }
  }

  func handleMessage(_ message: URLSessionWebSocketTask.Message) async throws {
    guard case .string(let text) = message else { return }
    guard let data = text.data(using: .utf8) else {
      throw WebSocketTransportError.unexpectedResponse
    }
    let frame = try decoder.decode(WsFrame.self, from: data)
    try await handleFrame(frame)
  }

  func handleFrame(_ frame: WsFrame) async throws {
    switch frame.kind {
    case .response(let id, let result, let error, let batchIndex, let batchCount):
      await handleResponseFrame(
        id: id,
        result: result,
        error: error,
        batchIndex: batchIndex,
        batchCount: batchCount
      )
    case .push(let event, let recordedAt, let sessionId, let payload, _):
      handlePushFrame(
        event: event,
        recordedAt: recordedAt,
        sessionId: sessionId,
        payload: payload
      )
    case .chunk(let chunkID, let chunkIndex, let chunkCount, let chunkBase64):
      guard
        let assembled = try appendChunk(
          id: chunkID,
          index: chunkIndex,
          count: chunkCount,
          base64: chunkBase64
        )
      else {
        return
      }
      let frame = try decoder.decode(WsFrame.self, from: assembled)
      try await handleFrame(frame)
    case .unknown:
      break
    }
  }

  func appendChunk(
    id: String,
    index: Int,
    count: Int,
    base64: String
  ) throws -> Data? {
    var pendingFrame = partialFrames[id] ?? PendingFrameChunks(expectedCount: count)
    let assembled = try pendingFrame.append(index: index, count: count, base64: base64)
    if assembled == nil {
      partialFrames[id] = pendingFrame
    } else {
      partialFrames.removeValue(forKey: id)
    }
    return assembled
  }

  func clearPartialFrames() {
    partialFrames.removeAll()
  }

  func clearResponseBatchHandler(for id: String) {
    responseBatchHandlers[id] = nil
  }

  func clearResponseBatchHandlers() {
    responseBatchHandlers.removeAll()
  }

  private func handleResponseFrame(
    id: String,
    result: JSONValue?,
    error: WsErrorPayload?,
    batchIndex: Int?,
    batchCount: Int?
  ) async {
    if let error {
      clearResponseBatchHandler(for: id)
      pending.fail(
        id: id,
        error: WebSocketTransportError.serverError(
          code: error.code,
          message: error.message
        )
      )
      return
    }

    if let batchIndex, let batchCount {
      do {
        if let handler = responseBatchHandlers[id] {
          try await handler(batchIndex, batchCount, result)
        }
        let completed = try pending.resumeBatch(
          id: id,
          index: batchIndex,
          count: batchCount,
          result: result
        )
        if completed {
          clearResponseBatchHandler(for: id)
        }
      } catch {
        clearResponseBatchHandler(for: id)
        pending.fail(id: id, error: error)
      }
      return
    }

    clearResponseBatchHandler(for: id)
    if let result {
      pending.resume(id: id, result: result)
    } else {
      pending.resume(id: id, result: .null)
    }
  }

  private func handlePushFrame(
    event: String,
    recordedAt: String,
    sessionId: String?,
    payload: JSONValue
  ) {
    let streamEvent = StreamEvent(
      event: event,
      recordedAt: recordedAt,
      sessionId: sessionId,
      payload: payload
    )
    do {
      let pushEvent = try DaemonPushEvent(streamEvent: streamEvent)
      globalStreamContinuation?.yield(pushEvent)
      if let sessionId, let continuation = sessionStreamContinuations[sessionId] {
        continuation.yield(pushEvent)
      }
    } catch {
      HarnessMonitorLogger.websocket.warning(
        "Dropping malformed push frame \(event, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func finishStreams(with error: any Error) {
    globalStreamContinuation?.finish(throwing: error)
    globalStreamContinuation = nil
    for (_, continuation) in sessionStreamContinuations {
      continuation.finish(throwing: error)
    }
    sessionStreamContinuations.removeAll()
  }

  func startHeartbeat() {
    heartbeatTask?.cancel()
    heartbeatTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(15))
        guard !Task.isCancelled, let self else { break }
        try? await self.sendPing()
      }
    }
  }

  func terminateAllStreams() {
    globalStreamContinuation?.finish()
    globalStreamContinuation = nil
    for (_, continuation) in sessionStreamContinuations {
      continuation.finish()
    }
    sessionStreamContinuations.removeAll()
    responseBatchHandlers.removeAll()
    partialFrames.removeAll()
  }

  func cancelWebSocketTaskIfNeeded(closeCode: URLSessionWebSocketTask.CloseCode) {
    guard let webSocketTask else {
      return
    }

    guard webSocketTask.state == .running, webSocketTask.closeCode == .invalid else {
      return
    }

    webSocketTask.cancel(with: closeCode, reason: nil)
  }

  nonisolated func wsEndpoint() -> URL {
    guard
      var components = URLComponents(
        url: connection.endpoint,
        resolvingAgainstBaseURL: false
      )
    else {
      return connection.endpoint
    }
    components.scheme =
      connection.endpoint.scheme == "https" ? "wss" : "ws"
    components.path = "/v1/ws"
    return components.url ?? connection.endpoint
  }

  private static let reencodeEncoder = JSONEncoder()
  private static let mergeDecoder = JSONDecoder()

  nonisolated func decode<T: Decodable>(_ value: JSONValue) throws -> T {
    let data = try Self.reencodeEncoder.encode(value)
    return try decoder.decode(T.self, from: data)
  }

  nonisolated func encodeParams<T: Encodable>(
    _ body: T,
    extra: [String: JSONValue]
  ) throws -> JSONValue {
    let data = try encoder.encode(body)
    guard
      var object = try JSONSerialization.jsonObject(with: data)
        as? [String: Any]
    else {
      return .null
    }
    for (key, value) in extra {
      if case .string(let stringValue) = value {
        object[key] = stringValue
      }
    }
    let merged = try JSONSerialization.data(withJSONObject: object)
    return try Self.mergeDecoder.decode(JSONValue.self, from: merged)
  }
}
