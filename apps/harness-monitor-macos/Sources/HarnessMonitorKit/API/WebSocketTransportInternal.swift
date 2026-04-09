import Foundation

// MARK: - Internal transport mechanics

extension WebSocketTransport {
  func sendPing() async throws {
    guard let webSocketTask else {
      throw WebSocketTransportError.connectionClosed
    }
    let task = webSocketTask
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
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
    return try await withCheckedThrowingContinuation { continuation in
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
  func send(method: String, params: JSONValue? = nil) async throws -> JSONValue {
    guard let webSocketTask else {
      throw WebSocketTransportError.connectionClosed
    }
    let id = UUID().uuidString
    let request = WsRequest(id: id, method: method, params: params)
    let data = try encoder.encode(request)
    let text = String(data: data, encoding: .utf8) ?? "{}"
    let task = webSocketTask
    let store = pending
    return try await withCheckedThrowingContinuation { continuation in
      store.register(id: id, continuation: continuation)
      task.send(.string(text)) { error in
        if let error {
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
          await self.handleMessage(message)
        } catch {
          if Task.isCancelled { return }
          self.pending.failAll(error: error)
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
          try? await self.reconnectInternal()
        }
      }
    }
  }

  func reconnectInternal() async throws {
    HarnessMonitorLogger.websocket.info("WebSocket reconnecting")
    heartbeatTask?.cancel()
    cancelWebSocketTaskIfNeeded(closeCode: .goingAway)
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

  func handleMessage(_ message: URLSessionWebSocketTask.Message) {
    guard case .string(let text) = message else { return }
    guard let data = text.data(using: .utf8) else { return }
    guard let frame = try? decoder.decode(WsFrame.self, from: data) else { return }

    switch frame.kind {
    case .response(let id, let result, let error):
      handleResponseFrame(id: id, result: result, error: error)
    case .push(let event, let recordedAt, let sessionId, let payload, _):
      handlePushFrame(
        event: event,
        recordedAt: recordedAt,
        sessionId: sessionId,
        payload: payload
      )
    case .unknown:
      break
    }
  }

  private func handleResponseFrame(
    id: String,
    result: JSONValue?,
    error: WsErrorPayload?
  ) {
    if let error {
      pending.fail(
        id: id,
        error: WebSocketTransportError.serverError(
          code: error.code,
          message: error.message
        )
      )
    } else if let result {
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
      finishStreams(with: error)
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
