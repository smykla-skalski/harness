import Foundation

extension WebSocketTransport {
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
          // The remote socket is dead. Drop the task reference so subsequent
          // `rpc()` / `sendPing()` calls fail-fast with `.connectionClosed`
          // instead of queueing sends into a dead URLSession task — the
          // avatar fan-out, latency probe, and stream-cleanup paths would
          // otherwise blast dozens of "Socket is not connected" failures
          // into the log per disconnect. `reconnectInternal()` allocates a
          // fresh task on each reconnect attempt regardless.
          await self.releaseDeadWebSocketTask()
          if Self.errorIndicatesEndpointGone(error) {
            HarnessMonitorLogger.websocket.info(
              "WebSocket endpoint is gone, yielding to store for manifest-driven re-bootstrap"
            )
            break
          }
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
    #if HARNESS_FEATURE_OTEL
      let requestID = HarnessMonitorTelemetry.shared.decorate(&request)
    #endif
    let task = session.webSocketTask(with: request)
    webSocketTask = task
    task.resume()
    startHeartbeat()
    try await resubscribe()
    emitReconnectReadyEvents()
    #if HARNESS_FEATURE_OTEL
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
    #endif
  }

  func resubscribe() async throws {
    if globalSubscriptionActive {
      _ = try await rpc(
        method: .streamSubscribe,
        params: .object(["scope": .string("global")])
      )
    }
    for sessionID in activeSubscriptions {
      _ = try await rpc(
        method: .sessionSubscribe,
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
      await handlePushFrame(
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

  func clearPendingRPCMethod(for id: String) {
    pendingRPCMethods[id] = nil
  }

  func clearResponseBatchHandlers() {
    responseBatchHandlers.removeAll()
  }

  func handleResponseFrame(
    id: String,
    result: JSONValue?,
    error: WsErrorPayload?,
    batchIndex: Int?,
    batchCount: Int?
  ) async {
    let method = pendingRPCMethods[id]
    if let error {
      clearResponseBatchHandler(for: id)
      clearPendingRPCMethod(for: id)
      pending.fail(
        id: id,
        error: responseError(method: method, error: error)
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
          clearPendingRPCMethod(for: id)
        }
      } catch {
        clearResponseBatchHandler(for: id)
        clearPendingRPCMethod(for: id)
        pending.fail(id: id, error: error)
      }
      return
    }

    clearResponseBatchHandler(for: id)
    clearPendingRPCMethod(for: id)
    if let result {
      pending.resume(id: id, result: result)
    } else {
      pending.resume(id: id, result: .null)
    }
  }
}
