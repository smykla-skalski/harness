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

  /// Drops the dead `webSocketTask` after a receive-loop failure. Does not
  /// call `cancel()`: the underlying socket is already gone, and writing a
  /// close frame to it would log a spurious
  /// `nw_socket_output_finished … shutdown(21, SHUT_WR)` warning. Letting
  /// ARC release the reference is enough — the URLSession task is already
  /// terminal from URLSession's point of view. Subsequent `rpc()` and
  /// `sendPing()` calls trip the `guard let webSocketTask else { throw … }`
  /// path and fail-fast instead of queueing into the dead socket.
  func releaseDeadWebSocketTask() {
    webSocketTask = nil
  }

  static let reencodeEncoder = JSONEncoder()
  private static let mergeDecoder = JSONDecoder()

  /// Decodes a wire value with `PolicyWireCoding.decoder` (no key strategy). Every
  /// daemon payload the transport decodes now carries explicit snake CodingKeys
  /// (generated wires plus the WsFrame envelope), so this is the sole decode path.
  nonisolated func decodePolicyWire<T: Decodable>(_ value: JSONValue) throws -> T {
    let data = try Self.reencodeEncoder.encode(value)
    return try PolicyWireCoding.decoder.decode(T.self, from: data)
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
      let wire: WsConfigPayloadWire = try decodePolicyWire(payload)
      let configuration = try MonitorConfiguration(wire: wire)
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
  ) async {
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
      enqueueDecodeFailureTelemetry(
        source: "swift.websocket.push",
        message: "Push frame \(event) decode failed: \(String(reflecting: error))",
        sample: encodedTelemetrySample(from: payload)
      )
      HarnessMonitorLogger.websocket.warning(
        "Dropping malformed push frame \(event, privacy: .public): \(err, privacy: .public)"
      )
    }
  }

  func deliverPushEvent(_ pushEvent: DaemonPushEvent) {
    if globalStreamContinuation == nil,
      let sessionId = pushEvent.sessionId,
      let continuation = sessionStreamContinuations[sessionId]
    {
      continuation.yield(pushEvent)
      return
    }
    if globalStreamContinuation == nil {
      // Sessions-only pushes arrive here when their continuation is also
      // gone (consumer stopped subscribing or transport is mid-reconnect).
      // Tag them with the session id when they carry one and the global
      // event name when they do not, so a regression report can locate
      // where in the pipeline the push was dropped.
      if let sessionId = pushEvent.sessionId {
        let eventLabel = pushEvent.kind.debugLabel
        HarnessMonitorLogger.websocket.debug(
          """
          dropping push \(eventLabel, privacy: .public) for session \
          \(sessionId, privacy: .public): no continuation attached
          """
        )
      } else {
        HarnessMonitorLogger.websocket.debug(
          "dropping global push \(pushEvent.kind.debugLabel, privacy: .public): no continuation attached"
        )
      }
      return
    }
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
      let wire: AcpEventBatchPayloadWire = try decodePolicyWire(payload)
      let batch = try AcpEventBatchPayload(wire: wire)
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
      enqueueDecodeFailureTelemetry(
        source: "swift.websocket.acp_events",
        message: "ACP event push decode failed: \(String(reflecting: error))",
        sample: encodedTelemetrySample(from: payload)
      )
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
    let overflowedBatches = pendingBatches.filter { $0.droppedRawCount > 0 }
    if !overflowedBatches.isEmpty {
      acpOverflowLogBurstCount += 1
      HarnessMonitorLogger.websocket.info(
        """
        ACP event coalescer overflowed across \(overflowedBatches.count) pending batches; \
        retained \(overflowedBatches.reduce(0) { $0 + $1.payload.events.count }) events from \
        \(overflowedBatches.reduce(0) { $0 + $1.rawCount }) raw updates and dropped \
        \(overflowedBatches.reduce(0) { $0 + $1.droppedRawCount }) oldest raw updates before flush. \
        Widening review required.
        """
      )
    }
    for batch in pendingBatches {
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
