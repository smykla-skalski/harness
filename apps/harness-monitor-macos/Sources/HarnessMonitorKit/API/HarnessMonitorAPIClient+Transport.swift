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
    let start = ContinuousClock.now
    let (data, response) = try await session.data(for: request)
    let elapsed = start.duration(to: .now)
    let durationMs =
      elapsed.components.seconds * 1000
      + Int64(elapsed.components.attoseconds / 1_000_000_000_000_000)
    let method = request.httpMethod ?? "?"
    let path = request.url?.path ?? "?"
    guard let httpResponse = response as? HTTPURLResponse else {
      HarnessMonitorLogger.api.error(
        "Invalid response for \(method, privacy: .public) \(path, privacy: .public)"
      )
      throw HarnessMonitorAPIError.invalidResponse
    }

    HarnessMonitorLogger.api.debug(
      "\(method, privacy: .public) \(path, privacy: .public) -> \(httpResponse.statusCode) (\(durationMs)ms)"
    )

    guard (200..<300).contains(httpResponse.statusCode) else {
      throw try decodeError(statusCode: httpResponse.statusCode, data: data)
    }

    return try decoder.decode(Response.self, from: data)
  }

  func stream(_ path: String) -> DaemonPushEventStream {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let request = try makeRequest(path: path)
          let (bytes, response) = try await session.bytes(for: request)
          guard let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
          else {
            throw HarnessMonitorAPIError.invalidResponse
          }

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
