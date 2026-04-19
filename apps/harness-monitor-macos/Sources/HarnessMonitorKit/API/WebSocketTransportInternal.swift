import Foundation
import OpenTelemetryApi

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
    let span = HarnessMonitorTelemetry.shared.startSpan(
      name: "daemon.websocket.rpc",
      kind: .client,
      attributes: [
        "transport.kind": .string("websocket"),
        "rpc.system": .string("harness-daemon"),
        "rpc.method": .string(method),
      ]
    )
    defer { span.end() }

    let startedAt = ContinuousClock.now
    let id = UUID().uuidString
    span.setAttribute(key: "rpc.request_id", value: id)
    let request = makeRequest(
      id: id,
      method: method,
      params: params,
      spanContext: span.context
    )
    let data = try encoder.encode(request)
    let text = String(data: data, encoding: .utf8) ?? "{}"
    let task = webSocketTask
    let store = pending
    if let onSemanticBatch {
      responseBatchHandlers[id] = onSemanticBatch
    }
    do {
      let result = try await withCheckedThrowingContinuation { continuation in
        store.register(id: id, continuation: continuation)
        task.send(.string(text)) { error in
          if let error {
            let errorDescription = error.localizedDescription
            HarnessMonitorLogger.websocket.warning(
              "WebSocket send failed for \(method, privacy: .public): \(errorDescription, privacy: .public)"
            )
            Task { await self.clearResponseBatchHandler(for: id) }
            store.fail(id: id, error: error)
          }
        }
      }
      let durationMs = harnessMonitorDurationMilliseconds(
        startedAt.duration(to: ContinuousClock.now)
      )
      HarnessMonitorTelemetry.shared.recordWebSocketRPC(
        method: method,
        durationMs: durationMs,
        failed: false
      )
      return result
    } catch {
      let durationMs = harnessMonitorDurationMilliseconds(
        startedAt.duration(to: ContinuousClock.now)
      )
      span.status = .error(description: error.localizedDescription)
      HarnessMonitorTelemetry.shared.recordError(error, on: span)
      HarnessMonitorTelemetry.shared.recordWebSocketRPC(
        method: method,
        durationMs: durationMs,
        failed: true
      )
      HarnessMonitorTelemetry.shared.emitLog(
        name: "daemon.websocket.rpc.failed",
        severity: .error,
        body: "WebSocket RPC failed",
        attributes: [
          "rpc.method": .string(method),
          "rpc.request_id": .string(id),
          "request.duration_ms": .double(durationMs),
          "error.message": .string(error.localizedDescription),
        ]
      )
      throw error
    }
  }

  func makeRequest(
    id: String,
    method: String,
    params: JSONValue? = nil,
    spanContext: SpanContext? = nil
  ) -> WsRequest {
    let traceContext = HarnessMonitorTelemetry.shared.traceContext(spanContext: spanContext)
    return WsRequest(
      id: id,
      method: method,
      params: params,
      traceContext: traceContext.isEmpty ? nil : traceContext
    )
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
          let errorDescription = error.localizedDescription
          HarnessMonitorLogger.websocket.warning(
            "WebSocket receive loop error (attempt \(attempt)): \(errorDescription, privacy: .public)"
          )
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
    let requestID = HarnessMonitorTelemetry.shared.decorate(&request)
    let task = session.webSocketTask(with: request)
    webSocketTask = task
    task.resume()
    startHeartbeat()
    try await resubscribe()
    emitReconnectReadyEvents()
    HarnessMonitorTelemetry.shared.recordWebSocketConnect(outcome: "reconnect")
    HarnessMonitorTelemetry.shared.emitLog(
      name: "daemon.websocket.reconnect",
      severity: .info,
      body: "WebSocket reconnect completed",
      attributes: [
        "request.id": .string(requestID),
        "url.absolute": .string(wsURL.absoluteString),
      ]
    )
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

  func emitReconnectReadyEvents() {
    let recordedAt = ISO8601DateFormatter().string(from: Date())
    if globalSubscriptionActive {
      globalStreamContinuation?.yield(.ready(recordedAt: recordedAt))
    }
    for (sessionID, continuation) in sessionStreamContinuations {
      continuation.yield(.ready(recordedAt: recordedAt, sessionId: sessionID))
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
    if event == "config" {
      handleConfigurationPush(payload: payload)
      return
    }
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
      let err = error.localizedDescription
      HarnessMonitorLogger.websocket.warning(
        "Dropping malformed push frame \(event, privacy: .public): \(err, privacy: .public)"
      )
    }
  }

}
