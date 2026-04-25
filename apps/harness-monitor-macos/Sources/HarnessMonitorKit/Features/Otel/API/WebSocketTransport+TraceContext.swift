import Foundation
import OpenTelemetryApi

extension WebSocketTransport {
  func recordRPCSuccess(method: String, startedAt: ContinuousClock.Instant) {
    let durationMs = harnessMonitorDurationMilliseconds(
      startedAt.duration(to: ContinuousClock.now)
    )
    HarnessMonitorTelemetry.shared.recordWebSocketRPC(
      method: method,
      durationMs: durationMs,
      failed: false
    )
  }

  func recordRPCFailure(
    error: any Error,
    method: String,
    requestID: String,
    startedAt: ContinuousClock.Instant,
    span: any Span
  ) {
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
        "rpc.request_id": .string(requestID),
        "request.duration_ms": .double(durationMs),
        "error.message": .string(error.localizedDescription),
      ]
    )
  }

  func makeRequest(
    id: String,
    method: String,
    params: JSONValue?,
    spanContext: SpanContext?
  ) -> WsRequest {
    let traceContext = HarnessMonitorTelemetry.shared.traceContext(spanContext: spanContext)
    return WsRequest(
      id: id,
      method: method,
      params: params,
      traceContext: traceContext.isEmpty ? nil : traceContext
    )
  }
}
