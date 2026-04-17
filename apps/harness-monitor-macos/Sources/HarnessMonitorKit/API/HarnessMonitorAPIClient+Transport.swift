import Foundation

struct EmptyBody: Encodable {}

struct AnyEncodable: Encodable {
  private let encodeClosure: (Encoder) throws -> Void

  init<Value: Encodable>(_ value: Value) {
    encodeClosure = value.encode(to:)
  }

  func encode(to encoder: Encoder) throws {
    try encodeClosure(encoder)
  }
}

struct FlatErrorEnvelope: Decodable {
  let error: String
  let feature: String?
  let endpoint: String?
  let hint: String?
}

extension HarnessMonitorAPIClient {
  func get<Response: Decodable>(_ path: String) async throws -> Response {
    var request = try makeRequest(path: path)
    request.httpMethod = "GET"
    return try await send(request)
  }

  func get<Response: Decodable>(
    _ path: String,
    queryItems: [URLQueryItem]
  ) async throws -> Response {
    var request = try makeRequest(path: path, queryItems: queryItems)
    request.httpMethod = "GET"
    return try await send(request)
  }

  func post<RequestBody: Encodable, Response: Decodable>(
    _ path: String,
    body: RequestBody
  ) async throws -> Response {
    var request = try makeRequest(path: path)
    request.httpMethod = "POST"
    request.httpBody = try encoder.encode(AnyEncodable(body))
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return try await send(request)
  }

  func put<RequestBody: Encodable, Response: Decodable>(
    _ path: String,
    body: RequestBody
  ) async throws -> Response {
    var request = try makeRequest(path: path)
    request.httpMethod = "PUT"
    request.httpBody = try encoder.encode(AnyEncodable(body))
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return try await send(request)
  }

  func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
    let method = request.httpMethod ?? "?"
    let path = request.url?.path ?? "?"
    let span = HarnessMonitorTelemetry.shared.startSpan(
      name: "daemon.http.request",
      kind: .client,
      attributes: [
        "transport.kind": .string("http"),
        "http.request.method": .string(method),
        "url.path": .string(path),
      ]
    )
    defer { span.end() }

    var request = request
    let requestID = HarnessMonitorTelemetry.shared.decorate(&request, spanContext: span.context)
    span.setAttribute(key: "harness.request_id", value: requestID)

    let start = ContinuousClock.now
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      let durationMs = harnessMonitorDurationMilliseconds(start.duration(to: .now))
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
        ]
      )
      throw error
    }

    let durationMs = harnessMonitorDurationMilliseconds(start.duration(to: .now))
    guard let httpResponse = response as? HTTPURLResponse else {
      HarnessMonitorLogger.api.error(
        "Invalid response for \(method, privacy: .public) \(path, privacy: .public)"
      )
      span.status = .error(description: "invalid response")
      let invalidResponse = HarnessMonitorAPIError.invalidResponse
      HarnessMonitorTelemetry.shared.recordError(invalidResponse, on: span)
      HarnessMonitorTelemetry.shared.recordHTTPRequest(
        method: method,
        path: path,
        statusCode: nil,
        durationMs: durationMs,
        failed: true
      )
      throw invalidResponse
    }

    span.setAttribute(key: "http.response.status_code", value: httpResponse.statusCode)
    HarnessMonitorLogger.api.debug(
      "\(method, privacy: .public) \(path, privacy: .public) -> \(httpResponse.statusCode) (\(Int64(durationMs))ms)"
    )

    guard (200..<300).contains(httpResponse.statusCode) else {
      let error = try decodeError(statusCode: httpResponse.statusCode, data: data)
      span.status = .error(description: error.localizedDescription)
      HarnessMonitorTelemetry.shared.recordError(error, on: span)
      HarnessMonitorTelemetry.shared.recordHTTPRequest(
        method: method,
        path: path,
        statusCode: httpResponse.statusCode,
        durationMs: durationMs,
        failed: true
      )
      HarnessMonitorTelemetry.shared.emitLog(
        name: "daemon.http.request.rejected",
        severity: .warn,
        body: "\(method) \(path) returned \(httpResponse.statusCode)",
        attributes: [
          "request.id": .string(requestID),
          "request.duration_ms": .double(durationMs),
          "http.response.status_code": .int(httpResponse.statusCode),
        ]
      )
      throw error
    }

    HarnessMonitorTelemetry.shared.recordHTTPRequest(
      method: method,
      path: path,
      statusCode: httpResponse.statusCode,
      durationMs: durationMs,
      failed: false
    )
    return try decoder.decode(Response.self, from: data)
  }

  func stream(_ path: String) -> DaemonPushEventStream {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let baseRequest = try makeRequest(path: path)
          let method = baseRequest.httpMethod ?? "GET"
          let span = HarnessMonitorTelemetry.shared.startSpan(
            name: "daemon.http.stream",
            kind: .client,
            attributes: [
              "transport.kind": .string("http"),
              "http.request.method": .string(method),
              "url.path": .string(path),
              "stream.kind": .string("sse"),
            ]
          )
          defer { span.end() }

          var request = baseRequest
          let requestID = HarnessMonitorTelemetry.shared.decorate(
            &request,
            spanContext: span.context
          )
          span.setAttribute(key: "harness.request_id", value: requestID)

          let start = ContinuousClock.now
          let (bytes, response) = try await session.bytes(for: request)
          let durationMs = harnessMonitorDurationMilliseconds(start.duration(to: .now))
          guard let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
          else {
            let error = HarnessMonitorAPIError.invalidResponse
            span.status = .error(description: error.localizedDescription)
            HarnessMonitorTelemetry.shared.recordError(error, on: span)
            HarnessMonitorTelemetry.shared.recordHTTPRequest(
              method: method,
              path: path,
              statusCode: (response as? HTTPURLResponse)?.statusCode,
              durationMs: durationMs,
              failed: true
            )
            throw error
          }

          span.setAttribute(key: "http.response.status_code", value: httpResponse.statusCode)
          HarnessMonitorTelemetry.shared.recordHTTPRequest(
            method: method,
            path: path,
            statusCode: httpResponse.statusCode,
            durationMs: durationMs,
            failed: false
          )

          var parser = ServerSentEventParser()
          for try await line in bytes.lines {
            if let frame = parser.push(line: line) {
              let event = try decoder.decode(
                StreamEvent.self,
                from: Data(frame.data.utf8)
              )
              continuation.yield(try DaemonPushEvent(streamEvent: event))
            }
          }

          if let frame = parser.finish() {
            let event = try decoder.decode(StreamEvent.self, from: Data(frame.data.utf8))
            continuation.yield(try DaemonPushEvent(streamEvent: event))
          }

          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  func makeRequest(
    path: String,
    queryItems: [URLQueryItem] = []
  ) throws -> URLRequest {
    guard let baseURL = URL(string: path, relativeTo: connection.endpoint) else {
      throw HarnessMonitorAPIError.invalidEndpoint(connection.endpoint.absoluteString)
    }
    guard
      var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true)
    else {
      throw HarnessMonitorAPIError.invalidEndpoint(connection.endpoint.absoluteString)
    }
    if !queryItems.isEmpty {
      components.queryItems = queryItems
    }
    guard let url = components.url else {
      throw HarnessMonitorAPIError.invalidEndpoint(connection.endpoint.absoluteString)
    }

    var request = URLRequest(url: url)
    request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return request
  }

  func decodeError(statusCode: Int, data: Data) throws -> HarnessMonitorAPIError {
    if let envelope = try? decoder.decode(ErrorEnvelope.self, from: data) {
      return .server(code: statusCode, message: envelope.error.message)
    }

    if let envelope = try? decoder.decode(FlatErrorEnvelope.self, from: data) {
      var parts = [envelope.error]
      if let feature = envelope.feature, !feature.isEmpty {
        parts.append(feature)
      }
      if let endpoint = envelope.endpoint, !endpoint.isEmpty {
        parts.append(endpoint)
      }
      if let hint = envelope.hint, !hint.isEmpty {
        parts.append(hint)
      }
      return .server(code: statusCode, message: parts.joined(separator: " - "))
    }

    let message = String(data: data, encoding: .utf8) ?? "Unknown daemon error"
    return .server(code: statusCode, message: message)
  }

}
