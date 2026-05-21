import Foundation

#if HARNESS_FEATURE_OTEL
  import OpenTelemetryApi
#endif
// MARK: - Internal transport mechanics

private typealias VoidPingContinuation = CheckedContinuation<Void, Error>
private typealias IntPingContinuation = CheckedContinuation<Int, Error>

final class ContinuationResumeGate: @unchecked Sendable {
  private let lock = NSLock()
  private var didResume = false

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
      return try await rpcSender(method, params, onSemanticBatch)
    }
    guard !isShutDown, let webSocketTask else {
      throw WebSocketTransportError.connectionClosed
    }
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
  private static let maxReconnectAttempts = reconnectDelays.count

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
