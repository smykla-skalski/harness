import Foundation

// MARK: - Internal transport mechanics

extension WebSocketTransport {
  @discardableResult
  func send(method: String, params: JSONValue? = nil) async throws -> JSONValue {
    guard let webSocketTask else {
      throw WebSocketTransportError.connectionClosed
    }
    let id = UUID().uuidString
    let request = WsRequest(id: id, method: method, params: params)
    let data = try encoder.encode(request)
    let text = String(data: data, encoding: .utf8) ?? "{}"
    return try await withCheckedThrowingContinuation { continuation in
      pending.register(id: id, continuation: continuation)
      webSocketTask.send(.string(text)) { [weak self] error in
        if let error {
          self?.pending.fail(id: id, error: error)
        }
      }
    }
  }

  func startReceiveLoop() {
    receiveTask?.cancel()
    receiveTask = Task { [weak self] in
      guard let self else { return }
      var attempt = 0
      while !Task.isCancelled {
        guard let webSocketTask = self.webSocketTask else { break }
        do {
          let message = try await webSocketTask.receive()
          attempt = 0
          self.handleMessage(message)
        } catch {
          if Task.isCancelled { return }
          self.pending.failAll(error: error)
          self.terminateAllStreams()
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
    heartbeatTask?.cancel()
    webSocketTask?.cancel(with: .goingAway, reason: nil)
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
      if let error {
        pending.fail(
          id: id,
          error: WebSocketTransportError.serverError(
            code: error.code, message: error.message)
        )
      } else if let result {
        pending.resume(id: id, result: result)
      } else {
        pending.resume(id: id, result: .null)
      }

    case .push(let event, let recordedAt, let sessionId, let payload, _):
      let streamEvent = StreamEvent(
        event: event,
        recordedAt: recordedAt,
        sessionId: sessionId,
        payload: payload
      )
      lock.withLock {
        globalStreamContinuation?.yield(streamEvent)
        if let sessionId, let continuation = sessionStreamContinuations[sessionId] {
          continuation.yield(streamEvent)
        }
      }

    case .unknown:
      break
    }
  }

  func startHeartbeat() {
    heartbeatTask?.cancel()
    heartbeatTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(15))
        guard !Task.isCancelled, let self else { break }
        _ = try? await self.send(method: "ping")
      }
    }
  }

  func terminateAllStreams() {
    lock.withLock {
      globalStreamContinuation?.finish()
      globalStreamContinuation = nil
      for (_, continuation) in sessionStreamContinuations {
        continuation.finish()
      }
      sessionStreamContinuations.removeAll()
    }
  }

  func wsEndpoint() -> URL {
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

  func decode<T: Decodable>(_ value: JSONValue) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try decoder.decode(T.self, from: data)
  }

  func encodeParams<T: Encodable>(
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
    return try JSONDecoder().decode(JSONValue.self, from: merged)
  }
}
