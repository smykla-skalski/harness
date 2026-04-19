import Foundation

extension WebSocketTransport {
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
    components.scheme = connection.endpoint.scheme == "https" ? "wss" : "ws"
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

  func handleConfigurationPush(payload: JSONValue) {
    do {
      let configuration: MonitorConfiguration = try decode(payload)
      cachedConfiguration = configuration
      let waiters = configurationWaiters
      configurationWaiters.removeAll()
      for waiter in waiters {
        waiter.resume(returning: configuration)
      }
    } catch {
      let err = error.localizedDescription
      HarnessMonitorLogger.websocket.warning(
        "Dropping malformed config push frame: \(err, privacy: .public)"
      )
    }
  }

  func finishStreams(with error: any Error) {
    globalStreamContinuation?.finish(throwing: error)
    globalStreamContinuation = nil
    for (_, continuation) in sessionStreamContinuations {
      continuation.finish(throwing: error)
    }
    sessionStreamContinuations.removeAll()
  }
}
