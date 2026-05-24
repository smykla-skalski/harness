import Foundation
import OpenTelemetryApi

extension HarnessMonitorAPIClient {
  func startHTTPSpan(
    method: String,
    path: String,
    request: inout URLRequest
  ) -> (any Span, String) {
    let span = HarnessMonitorTelemetry.shared.startSpan(
      name: "daemon.http.request",
      kind: .client,
      attributes: [
        "transport.kind": .string("http"),
        "http.request.method": .string(method),
        "url.path": .string(path),
      ]
    )
    let requestID = HarnessMonitorTelemetry.shared.decorate(
      &request,
      spanContext: span.context
    )
    span.setAttribute(key: "harness.request_id", value: requestID)
    return (span, requestID)
  }

  func recordHTTPSuccess(
    method: String,
    path: String,
    status: Int,
    durationMs: Double,
    span: any Span
  ) {
    span.setAttribute(key: "http.response.status_code", value: status)
    HarnessMonitorTelemetry.shared.recordHTTPRequest(
      method: method,
      path: path,
      statusCode: status,
      durationMs: durationMs,
      failed: false
    )
  }

  func recordTransportFailure(
    _ error: any Error,
    request: URLRequest,
    requestID: String,
    durationMs: Double,
    span: any Span
  ) {
    let method = request.httpMethod ?? "?"
    let path = request.url?.path ?? "?"

    let errorType: String
    if let urlError = error as? URLError {
      switch urlError.code {
      case .timedOut:
        errorType = "timeout"
        HarnessMonitorTelemetry.shared.recordTimeoutError(
          operation: "http_request", durationMs: durationMs
        )
      case .networkConnectionLost:
        errorType = "connection_lost"
      case .notConnectedToInternet:
        errorType = "offline"
      case .cannotConnectToHost:
        errorType = "connection_refused"
      default:
        errorType = "url_error_\(urlError.code.rawValue)"
      }
    } else if error is DecodingError {
      errorType = "decoding"
      HarnessMonitorTelemetry.shared.recordDecodingError(
        entity: path, reason: String(describing: error)
      )
    } else {
      errorType = "unknown"
    }

    HarnessMonitorTelemetry.shared.recordAPIError(
      endpoint: path, method: method, errorType: errorType, statusCode: nil
    )
    HarnessMonitorTelemetry.shared.recordError(error, on: span)
    span.status = .error(description: error.localizedDescription)
    HarnessMonitorTelemetry.shared.recordHTTPRequest(
      method: method,
      path: path,
      statusCode: nil,
      durationMs: durationMs,
      failed: true
    )
    HarnessMonitorTelemetry.shared.emitLog(
      name: "daemon.http.request.failed",
      severity: .error,
      body: "\(method) \(path) failed",
      attributes: [
        "request.id": .string(requestID),
        "request.duration_ms": .double(durationMs),
        "error.message": .string(error.localizedDescription),
        "error.type": .string(errorType),
      ]
    )
  }

  struct HTTPRejectionContext {
    let method: String
    let path: String
    let status: Int
    let durationMs: Double
    let requestID: String
  }

  func recordHTTPRejection(
    error: any Error,
    context: HTTPRejectionContext,
    span: any Span
  ) {
    span.status = .error(description: error.localizedDescription)
    HarnessMonitorTelemetry.shared.recordError(error, on: span)
    HarnessMonitorTelemetry.shared.recordHTTPRequest(
      method: context.method,
      path: context.path,
      statusCode: context.status,
      durationMs: context.durationMs,
      failed: true
    )
    HarnessMonitorTelemetry.shared.emitLog(
      name: "daemon.http.request.rejected",
      severity: .warn,
      body: "\(context.method) \(context.path) returned \(context.status)",
      attributes: [
        "request.id": .string(context.requestID),
        "request.duration_ms": .double(context.durationMs),
        "http.response.status_code": .int(context.status),
      ]
    )
  }

  func recordHTTPDecodingFailure(error: any Error, path: String, span: any Span) {
    HarnessMonitorTelemetry.shared.recordDecodingError(
      entity: path, reason: String(describing: error)
    )
    span.status = .error(description: "decoding failed")
    HarnessMonitorTelemetry.shared.recordError(error, on: span)
  }

  func recordInvalidHTTPResponse(
    method: String,
    path: String,
    durationMs: Double,
    span: any Span
  ) -> HarnessMonitorAPIError {
    HarnessMonitorLogger.api.error(
      "Invalid response for \(method, privacy: .public) \(path, privacy: .public)"
    )
    let invalidResponse = HarnessMonitorAPIError.invalidResponse
    span.status = .error(description: "invalid response")
    HarnessMonitorTelemetry.shared.recordError(invalidResponse, on: span)
    HarnessMonitorTelemetry.shared.recordHTTPRequest(
      method: method,
      path: path,
      statusCode: nil,
      durationMs: durationMs,
      failed: true
    )
    return invalidResponse
  }
}
