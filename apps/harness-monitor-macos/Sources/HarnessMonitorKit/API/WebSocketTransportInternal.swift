import Foundation

#if HARNESS_FEATURE_OTEL
  import OpenTelemetryApi
#endif
// MARK: - Internal transport mechanics

typealias VoidPingContinuation = CheckedContinuation<Void, Error>
typealias IntPingContinuation = CheckedContinuation<Int, Error>

final class ContinuationResumeGate: @unchecked Sendable {
  let lock = NSLock()
  var didResume = false

  func tryBeginResume() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !didResume else {
      return false
    }
    didResume = true
    return true
  }
}

extension WebSocketTransport {
  static let pingTimeout: Duration = .seconds(5)

  func sendPing() async throws {
    guard let webSocketTask else {
      throw WebSocketTransportError.connectionClosed
    }
    let task = webSocketTask
    try await withCheckedThrowingContinuation { (continuation: VoidPingContinuation) in
      let gate = ContinuationResumeGate()
      let timeoutTask = Task {
        try? await Task.sleep(for: Self.pingTimeout)
        guard gate.tryBeginResume() else { return }
        continuation.resume(throwing: URLError(.timedOut))
      }
      task.sendPing { error in
        guard gate.tryBeginResume() else {
          HarnessMonitorLogger.websocket.warning(
            "Ignoring duplicate WebSocket ping completion callback"
          )
          return
        }
        timeoutTask.cancel()
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
      let gate = ContinuationResumeGate()
      let timeoutTask = Task {
        try? await Task.sleep(for: Self.pingTimeout)
        guard gate.tryBeginResume() else { return }
        continuation.resume(throwing: URLError(.timedOut))
      }
      task.sendPing { error in
        guard gate.tryBeginResume() else {
          HarnessMonitorLogger.websocket.warning(
            "Ignoring duplicate WebSocket latency ping completion callback"
          )
          return
        }
        timeoutTask.cancel()
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
  func rpc(
    method: WebSocketRPCMethod,
    params: JSONValue? = nil,
    onSemanticBatch: ResponseBatchHandler? = nil
  ) async throws -> JSONValue {
    if let rpcSender {
      return try await rpcViaInjectedSender(
        rpcSender,
        method: method,
        params: params,
        onSemanticBatch: onSemanticBatch
      )
    }
    guard !isShutDown, let webSocketTask else {
      throw WebSocketTransportError.connectionClosed
    }
    return try await rpcOverWebSocket(
      method: method,
      params: params,
      onSemanticBatch: onSemanticBatch,
      webSocketTask: webSocketTask
    )
  }

  private func rpcViaInjectedSender(
    _ rpcSender: @escaping RPCSender,
    method: WebSocketRPCMethod,
    params: JSONValue?,
    onSemanticBatch: ResponseBatchHandler?
  ) async throws -> JSONValue {
    let timeout = rpcTimeout
    let outcome = AsyncStream<RPCSenderOutcome>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    let workTask = Task.detached(priority: .userInitiated) {
      do {
        let value = try await rpcSender(method, params, onSemanticBatch)
        outcome.continuation.yield(.success(value))
      } catch {
        outcome.continuation.yield(.failure(error))
      }
    }
    let timeoutTask = Task.detached {
      do {
        try await Task.sleep(for: timeout)
        outcome.continuation.yield(.failure(WebSocketTransportError.requestTimedOut))
      } catch {
        // sleep cancelled before timeout fired; the work task already won
      }
    }
    defer {
      workTask.cancel()
      timeoutTask.cancel()
      outcome.continuation.finish()
    }
    var iterator = outcome.stream.makeAsyncIterator()
    guard let first = await iterator.next() else {
      throw WebSocketTransportError.requestTimedOut
    }
    switch first {
    case .success(let value): return value
    case .failure(let error): throw error
    }
  }

  private func rpcOverWebSocket(
    method: WebSocketRPCMethod,
    params: JSONValue?,
    onSemanticBatch: ResponseBatchHandler?,
    webSocketTask task: URLSessionWebSocketTask
  ) async throws -> JSONValue {
    #if HARNESS_FEATURE_OTEL
      let span = HarnessMonitorTelemetry.shared.startSpan(
        name: "daemon.websocket.rpc",
        kind: .client,
        attributes: [
          "transport.kind": .string("websocket"),
          "rpc.system": .string("harness-daemon"),
          "rpc.method": .string(method.rawValue),
        ]
      )
      defer { span.end() }
    #endif

    let startedAt = ContinuousClock.now
    let id = HarnessMonitorRequestID.next()
    #if HARNESS_FEATURE_OTEL
      span.setAttribute(key: "rpc.request_id", value: id)
    #endif
    pendingRPCMethods[id] = method
    #if HARNESS_FEATURE_OTEL
      let request = makeRequest(
        id: id,
        method: method.rawValue,
        params: params,
        spanContext: span.context
      )
    #else
      let request = makeRequest(
        id: id,
        method: method.rawValue,
        params: params
      )
    #endif
    let data = try encoder.encode(request)
    let text = String(data: data, encoding: .utf8) ?? "{}"
    let store = pending
    if let onSemanticBatch {
      responseBatchHandlers[id] = onSemanticBatch
    }
    let timeoutTask = makeRPCTimeoutTask(
      id: id,
      method: method,
      store: store
    )
    defer { timeoutTask.cancel() }
    do {
      let result = try await sendRPCRequest(
        method: method,
        id: id,
        text: text,
        task: task,
        store: store
      )
      #if HARNESS_FEATURE_OTEL
        recordRPCSuccess(method: method.rawValue, startedAt: startedAt)
      #else
        _ = startedAt
      #endif
      return result
    } catch {
      #if HARNESS_FEATURE_OTEL
        recordRPCFailure(
          error: error,
          method: method.rawValue,
          requestID: id,
          startedAt: startedAt,
          span: span
        )
      #endif
      throw error
    }
  }

  private func makeRPCTimeoutTask(
    id: String,
    method: WebSocketRPCMethod,
    store: PendingRequestStore
  ) -> Task<Void, Never> {
    let timeout = rpcTimeout
    return Task { [weak self] in
      do {
        try await Task.sleep(for: timeout)
      } catch {
        return
      }
      store.fail(id: id, error: WebSocketTransportError.requestTimedOut)
      HarnessMonitorLogger.websocket.warning(
        """
        WebSocket RPC \(method.rawValue, privacy: .public) timed out after \
        \(timeout.components.seconds, privacy: .public)s; failing pending request \
        \(id, privacy: .public)
        """
      )
      if let self {
        Task { await self.clearResponseBatchHandler(for: id) }
        Task { await self.clearPendingRPCMethod(for: id) }
      }
    }
  }

  private func sendRPCRequest(
    method: WebSocketRPCMethod,
    id: String,
    text: String,
    task: URLSessionWebSocketTask,
    store: PendingRequestStore
  ) async throws -> JSONValue {
    try await withCheckedThrowingContinuation { continuation in
      store.register(id: id, continuation: continuation)
      task.send(.string(text)) { error in
        if let error {
          let errorDescription = error.localizedDescription
          HarnessMonitorLogger.websocket.warning(
            """
            WebSocket send failed for \(method.rawValue, privacy: .public): \
            \(errorDescription, privacy: .public)
            """
          )
          Task { await self.clearResponseBatchHandler(for: id) }
          Task { await self.clearPendingRPCMethod(for: id) }
          store.fail(id: id, error: error)
        }
      }
    }
  }

  /// Used by the rpcSender timeout race in `rpc(method:params:onSemanticBatch:)`
  /// to wedge results and timeouts onto the same single-slot `AsyncStream`.
  private enum RPCSenderOutcome: Sendable {
    case success(JSONValue)
    case failure(any Error)
  }

  func makeRequest(
    id: String,
    method: String,
    params: JSONValue? = nil
  ) -> WsRequest {
    WsRequest(
      id: id,
      method: method,
      params: params,
      traceContext: nil
    )
  }

  /// Maximum internal WS reconnection attempts before giving up and
  /// letting the store-level retry escalate to a full re-bootstrap
  /// (which re-reads the daemon manifest and discovers the new port).
  static let maxReconnectAttempts = reconnectDelays.count

  /// True when the error means the remote port is gone (daemon process
  /// died or was killed). Retrying the same endpoint will never succeed —
  /// the manifest watcher's re-bootstrap path is the only thing that can
  /// recover, so yield to the store immediately instead of looping for
  /// ~15 seconds against a closed loopback port.
  static func errorIndicatesEndpointGone(_ error: any Error) -> Bool {
    if let urlError = error as? URLError {
      switch urlError.code {
      case .cannotConnectToHost, .networkConnectionLost:
        return true
      default:
        break
      }
    }
    let nsError = error as NSError
    if nsError.domain == NSPOSIXErrorDomain {
      // ECONNREFUSED is the canonical "no one is listening on that port"
      // signal we get when the daemon has exited.
      return nsError.code == Int(ECONNREFUSED)
    }
    return false
  }
}
