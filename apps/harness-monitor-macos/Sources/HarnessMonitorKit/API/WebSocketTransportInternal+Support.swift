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
    clearPendingAcpEventPushes()
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

  func deliverPushFrame(
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
      deliverPushEvent(pushEvent)
    } catch {
      let err = error.localizedDescription
      HarnessMonitorLogger.websocket.warning(
        "Dropping malformed push frame \(event, privacy: .public): \(err, privacy: .public)"
      )
    }
  }

  func deliverPushEvent(_ pushEvent: DaemonPushEvent) {
    globalStreamContinuation?.yield(pushEvent)
    if let sessionId = pushEvent.sessionId,
      let continuation = sessionStreamContinuations[sessionId]
    {
      continuation.yield(pushEvent)
    }
  }

  func enqueueAcpEventPush(
    recordedAt: String,
    sessionId: String?,
    payload: JSONValue
  ) async {
    guard let sessionId else {
      HarnessMonitorLogger.websocket.warning(
        "Dropping malformed push frame acp_events: missing session id"
      )
      return
    }
    do {
      let batch: AcpEventBatchPayload = try decode(payload)
      guard batch.sessionId == sessionId else {
        HarnessMonitorLogger.websocket.warning(
          """
          Dropping malformed push frame acp_events: payload session id \
          \(batch.sessionId, privacy: .public) did not match frame session id \
          \(sessionId, privacy: .public)
          """
        )
        return
      }
      let key = PendingAcpEventPushKey(sessionId: sessionId, acpId: batch.acpId)
      if var pendingBatch = pendingAcpEventPushes[key] {
        pendingBatch.merge(
          recordedAt: recordedAt,
          payload: batch,
          maxRetainedEvents: Self.maxCoalescedAcpEvents
        )
        pendingAcpEventPushes[key] = pendingBatch
      } else {
        pendingAcpEventPushes[key] = PendingAcpEventPushBatch(
          recordedAt: recordedAt,
          payload: batch,
          maxRetainedEvents: Self.maxCoalescedAcpEvents
        )
        pendingAcpEventPushOrder.append(key)
      }
      schedulePendingAcpEventFlushIfNeeded()
    } catch {
      HarnessMonitorLogger.websocket.warning(
        """
        Dropping malformed push frame acp_events: \(error.localizedDescription, privacy: .public)
        """
      )
    }
  }

  func schedulePendingAcpEventFlushIfNeeded() {
    guard acpEventAutoFlushEnabled else {
      return
    }
    guard pendingAcpEventFlushTask == nil else {
      return
    }
    pendingAcpEventFlushTask = Task { [weak self] in
      await Task.yield()
      await self?.flushPendingAcpEventPushes()
    }
  }

  func flushPendingAcpEventPushes() {
    pendingAcpEventFlushTask = nil
    let pendingKeys = pendingAcpEventPushOrder
    pendingAcpEventPushOrder.removeAll()
    let pendingBatches = pendingKeys.compactMap { key in
      pendingAcpEventPushes.removeValue(forKey: key)
    }
    for batch in pendingBatches {
      if batch.droppedRawCount > 0 {
        acpOverflowLogBurstCount += 1
        HarnessMonitorLogger.websocket.info(
          """
          ACP event coalescer overflowed for session \(batch.sessionId, privacy: .public) \
          agent \(batch.acpId, privacy: .public); retained \(batch.payload.events.count) \
          events from \(batch.rawCount) raw updates and dropped \
          \(batch.droppedRawCount) oldest raw updates before flush. \
          Widening review required.
          """
        )
      }
      deliverPushEvent(
        DaemonPushEvent(
          recordedAt: batch.recordedAt,
          sessionId: batch.sessionId,
          kind: .acpEvents(batch.payload)
        )
      )
    }
  }

  func clearPendingAcpEventPushes() {
    pendingAcpEventFlushTask?.cancel()
    pendingAcpEventFlushTask = nil
    pendingAcpEventPushes.removeAll()
    pendingAcpEventPushOrder.removeAll()
  }

  func acpOverflowLogBurstCountForTests() -> Int {
    acpOverflowLogBurstCount
  }

  func setAcpEventAutoFlushEnabledForTests(_ enabled: Bool) {
    acpEventAutoFlushEnabled = enabled
  }
}
