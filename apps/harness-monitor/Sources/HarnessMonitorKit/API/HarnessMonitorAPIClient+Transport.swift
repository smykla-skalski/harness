import Foundation

#if HARNESS_FEATURE_OTEL
  import OpenTelemetryApi
#endif

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

extension HarnessMonitorAPIClient {
  func get<Response: Decodable>(
    _ path: String,
    decoder: JSONDecoder? = nil
  ) async throws -> Response {
    var request = try makeRequest(path: path)
    request.httpMethod = "GET"
    return try await send(request, decoder: decoder)
  }

  func get<Response: Decodable>(
    _ path: String,
    queryItems: [URLQueryItem],
    decoder: JSONDecoder? = nil
  ) async throws -> Response {
    var request = try makeRequest(path: path, queryItems: queryItems)
    request.httpMethod = "GET"
    return try await send(request, decoder: decoder)
  }

  func post<RequestBody: Encodable, Response: Decodable>(
    _ path: String,
    body: RequestBody,
    decoder: JSONDecoder? = nil
  ) async throws -> Response {
    var request = try makeRequest(path: path)
    request.httpMethod = "POST"
    request.httpBody = try encoder.encode(AnyEncodable(body))
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return try await send(request, decoder: decoder)
  }

  // SessionDetail is the aggregate every session-mutation endpoint returns. These decode the
  // generated SessionDetailWire through the plain decoder and fold it onto the rich model, so the
  // call sites stay one-liners instead of repeating the wire + map at each endpoint.
  func postSessionDetail(_ path: String, body: some Encodable) async throws -> SessionDetail {
    let wire: SessionDetailWire = try await post(
      path, body: body, decoder: PolicyWireCoding.decoder
    )
    return try SessionDetail(wire: wire)
  }

  func getSessionDetail(_ path: String) async throws -> SessionDetail {
    let wire: SessionDetailWire = try await get(path, decoder: PolicyWireCoding.decoder)
    return try SessionDetail(wire: wire)
  }

  func put<RequestBody: Encodable, Response: Decodable>(
    _ path: String,
    body: RequestBody,
    decoder: JSONDecoder? = nil
  ) async throws -> Response {
    var request = try makeRequest(path: path)
    request.httpMethod = "PUT"
    request.httpBody = try encoder.encode(AnyEncodable(body))
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return try await send(request, decoder: decoder)
  }

  func delete<Response: Decodable>(
    _ path: String,
    decoder: JSONDecoder? = nil
  ) async throws -> Response {
    var request = try makeRequest(path: path)
    request.httpMethod = "DELETE"
    return try await send(request, decoder: decoder)
  }

  func send<Response: Decodable>(
    _ request: URLRequest,
    decoder customDecoder: JSONDecoder? = nil
  ) async throws -> Response {
    let method = request.httpMethod ?? "?"
    let path = request.url?.path ?? "?"
    var request = request
    #if HARNESS_FEATURE_OTEL
      let (span, requestID) = startHTTPSpan(method: method, path: path, request: &request)
      defer { span.end() }
    #endif
    let start = ContinuousClock.now
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      let durationMs = harnessMonitorDurationMilliseconds(start.duration(to: .now))
      #if HARNESS_FEATURE_OTEL
        recordTransportFailure(
          error,
          request: request,
          requestID: requestID,
          durationMs: durationMs,
          span: span
        )
      #else
        _ = durationMs
      #endif
      throw error
    }

    let durationMs = harnessMonitorDurationMilliseconds(start.duration(to: .now))
    guard let httpResponse = response as? HTTPURLResponse else {
      #if HARNESS_FEATURE_OTEL
        let invalidResponse = recordInvalidHTTPResponse(
          method: method,
          path: path,
          durationMs: durationMs,
          span: span
        )
      #else
        HarnessMonitorLogger.api.error(
          "Invalid response for \(method, privacy: .public) \(path, privacy: .public)"
        )
        let invalidResponse = HarnessMonitorAPIError.invalidResponse
      #endif
      throw invalidResponse
    }

    logHTTPResponse(method: method, path: path, response: httpResponse, durationMs: durationMs)

    guard (200..<300).contains(httpResponse.statusCode) else {
      let error = Self.decodeError(statusCode: httpResponse.statusCode, data: data)
      #if HARNESS_FEATURE_OTEL
        recordHTTPRejection(
          error: error,
          context: HTTPRejectionContext(
            method: method,
            path: path,
            status: httpResponse.statusCode,
            durationMs: durationMs,
            requestID: requestID
          ),
          span: span
        )
      #endif
      throw error
    }

    #if HARNESS_FEATURE_OTEL
      recordHTTPSuccess(
        method: method,
        path: path,
        status: httpResponse.statusCode,
        durationMs: durationMs,
        span: span
      )
    #endif
    do {
      return try (customDecoder ?? decoder).decode(Response.self, from: data)
    } catch {
      #if HARNESS_FEATURE_OTEL
        recordHTTPDecodingFailure(error: error, path: path, span: span)
      #endif
      enqueueDecodeFailureTelemetry(
        source: "swift.http.response",
        message: "\(method) \(path) decode failed: \(String(reflecting: error))",
        sample: DaemonTelemetrySupport.truncatedSample(data)
      )
      throw error
    }
  }

  private func logHTTPResponse(
    method: String,
    path: String,
    response: HTTPURLResponse,
    durationMs: Double
  ) {
    HarnessMonitorLogger.api.debug(
      """
      \(method, privacy: .public) \(path, privacy: .public) \
      -> \(response.statusCode) (\(Int64(durationMs))ms)
      """
    )
  }

  func stream(_ path: String) -> DaemonPushEventStream {
    AsyncThrowingStream { continuation in
      let task = Task {
        await runStreamTask(path: path, continuation: continuation)
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  private func runStreamTask(
    path: String,
    continuation: AsyncThrowingStream<DaemonPushEvent, Error>.Continuation
  ) async {
    do {
      let streamContext = try await openEventStream(path: path)
      try await consumeEventStream(
        streamContext.bytes,
        path: path,
        continuation: continuation
      )
      continuation.finish()
    } catch {
      continuation.finish(throwing: error)
    }
  }

  private struct EventStreamContext {
    let bytes: URLSession.AsyncBytes
  }

  private func openEventStream(path: String) async throws -> EventStreamContext {
    let baseRequest = try makeRequest(path: path)
    let method = baseRequest.httpMethod ?? "GET"
    #if HARNESS_FEATURE_OTEL
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
    #endif

    var request = baseRequest
    #if HARNESS_FEATURE_OTEL
      let requestID = HarnessMonitorTelemetry.shared.decorate(
        &request,
        spanContext: span.context
      )
      span.setAttribute(key: "harness.request_id", value: requestID)
    #endif

    let start = ContinuousClock.now
    let (bytes, response) = try await session.bytes(for: request)
    let durationMs = harnessMonitorDurationMilliseconds(start.duration(to: .now))
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      let error = HarnessMonitorAPIError.invalidResponse
      #if HARNESS_FEATURE_OTEL
        span.status = .error(description: error.localizedDescription)
        HarnessMonitorTelemetry.shared.recordError(error, on: span)
        HarnessMonitorTelemetry.shared.recordHTTPRequest(
          method: method,
          path: path,
          statusCode: (response as? HTTPURLResponse)?.statusCode,
          durationMs: durationMs,
          failed: true
        )
      #else
        _ = durationMs
      #endif
      throw error
    }

    #if HARNESS_FEATURE_OTEL
      span.setAttribute(key: "http.response.status_code", value: httpResponse.statusCode)
      HarnessMonitorTelemetry.shared.recordHTTPRequest(
        method: method,
        path: path,
        statusCode: httpResponse.statusCode,
        durationMs: durationMs,
        failed: false
      )
    #else
      _ = durationMs
      _ = method
    #endif

    return EventStreamContext(bytes: bytes)
  }

  private func consumeEventStream(
    _ bytes: URLSession.AsyncBytes,
    path: String,
    continuation: AsyncThrowingStream<DaemonPushEvent, Error>.Continuation
  ) async throws {
    var parser = ServerSentEventParser()
    for try await line in bytes.lines {
      if let frame = parser.push(line: line) {
        try yieldStreamFrame(frame.data, path: path, continuation: continuation)
      }
    }

    if let frame = parser.finish() {
      try yieldStreamFrame(
        frame.data,
        path: path,
        continuation: continuation,
        isTrailingFrame: true
      )
    }
  }

  private func yieldStreamFrame(
    _ data: String,
    path: String,
    continuation: AsyncThrowingStream<DaemonPushEvent, Error>.Continuation,
    isTrailingFrame: Bool = false
  ) throws {
    do {
      let event = try decoder.decode(StreamEvent.self, from: Data(data.utf8))
      continuation.yield(try DaemonPushEvent(streamEvent: event))
    } catch {
      logMalformedStreamFrame(
        data,
        path: path,
        error: error,
        isTrailingFrame: isTrailingFrame
      )
    }
  }

  private func logMalformedStreamFrame(
    _ data: String,
    path: String,
    error: Error,
    isTrailingFrame: Bool
  ) {
    let frameLabel = isTrailingFrame ? "Final SSE frame" : "SSE frame"
    enqueueDecodeFailureTelemetry(
      source: "swift.http.stream",
      message: "\(frameLabel) for \(path) decode failed: \(String(reflecting: error))",
      sample: DaemonTelemetrySupport.truncatedSample(data)
    )
    let droppedLabel = isTrailingFrame ? "trailing SSE frame" : "SSE frame"
    HarnessMonitorLogger.api.warning(
      """
      Dropping malformed \(droppedLabel, privacy: .public) for \(path, privacy: .public): \
      \(error.localizedDescription, privacy: .public)
      """
    )
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

}
