import Foundation

public protocol MonitorClientProtocol: Sendable {
  func health() async throws -> HealthResponse
  func projects() async throws -> [ProjectSummary]
  func sessions() async throws -> [SessionSummary]
  func sessionDetail(id: String) async throws -> SessionDetail
  func timeline(sessionID: String) async throws -> [TimelineEntry]
  func globalStream() -> AsyncThrowingStream<StreamEvent, Error>
  func sessionStream(sessionID: String) -> AsyncThrowingStream<StreamEvent, Error>
  func createTask(sessionID: String, request: TaskCreateRequest) async throws -> SessionDetail
  func assignTask(
    sessionID: String,
    taskID: String,
    request: TaskAssignRequest
  ) async throws -> SessionDetail
  func updateTask(
    sessionID: String,
    taskID: String,
    request: TaskUpdateRequest
  ) async throws -> SessionDetail
  func checkpointTask(
    sessionID: String,
    taskID: String,
    request: TaskCheckpointRequest
  ) async throws -> SessionDetail
  func changeRole(
    sessionID: String,
    agentID: String,
    request: RoleChangeRequest
  ) async throws -> SessionDetail
  func transferLeader(
    sessionID: String,
    request: LeaderTransferRequest
  ) async throws -> SessionDetail
  func endSession(
    sessionID: String,
    request: SessionEndRequest
  ) async throws -> SessionDetail
  func sendSignal(
    sessionID: String,
    request: SignalSendRequest
  ) async throws -> SessionDetail
  func observeSession(sessionID: String) async throws -> SessionDetail
}

public struct MonitorConnection: Equatable, Sendable {
  public let endpoint: URL
  public let token: String

  public init(endpoint: URL, token: String) {
    self.endpoint = endpoint
    self.token = token
  }
}

public enum MonitorAPIError: Error, LocalizedError, Equatable {
  case invalidEndpoint(String)
  case invalidResponse
  case server(code: Int, message: String)

  public var errorDescription: String? {
    switch self {
    case .invalidEndpoint(let value):
      "Invalid daemon endpoint: \(value)"
    case .invalidResponse:
      "The daemon returned an invalid response."
    case .server(let code, let message):
      "Daemon error \(code): \(message)"
    }
  }
}

public final class MonitorAPIClient: MonitorClientProtocol {
  private let connection: MonitorConnection
  private let decoder: JSONDecoder
  private let encoder: JSONEncoder
  private let session: URLSession

  public init(connection: MonitorConnection, session: URLSession = .shared) {
    self.connection = connection
    self.session = session

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    self.decoder = decoder

    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    self.encoder = encoder
  }

  public func health() async throws -> HealthResponse {
    try await get("/v1/health")
  }

  public func projects() async throws -> [ProjectSummary] {
    try await get("/v1/projects")
  }

  public func sessions() async throws -> [SessionSummary] {
    try await get("/v1/sessions")
  }

  public func sessionDetail(id: String) async throws -> SessionDetail {
    try await get("/v1/sessions/\(id)")
  }

  public func timeline(sessionID: String) async throws -> [TimelineEntry] {
    try await get("/v1/sessions/\(sessionID)/timeline")
  }

  public func globalStream() -> AsyncThrowingStream<StreamEvent, Error> {
    stream("/v1/stream")
  }

  public func sessionStream(sessionID: String) -> AsyncThrowingStream<StreamEvent, Error> {
    stream("/v1/sessions/\(sessionID)/stream")
  }

  public func createTask(
    sessionID: String,
    request: TaskCreateRequest
  ) async throws -> SessionDetail {
    try await post("/v1/sessions/\(sessionID)/task", body: request)
  }

  public func assignTask(
    sessionID: String,
    taskID: String,
    request: TaskAssignRequest
  ) async throws -> SessionDetail {
    try await post("/v1/sessions/\(sessionID)/tasks/\(taskID)/assign", body: request)
  }

  public func updateTask(
    sessionID: String,
    taskID: String,
    request: TaskUpdateRequest
  ) async throws -> SessionDetail {
    try await post("/v1/sessions/\(sessionID)/tasks/\(taskID)/status", body: request)
  }

  public func checkpointTask(
    sessionID: String,
    taskID: String,
    request: TaskCheckpointRequest
  ) async throws -> SessionDetail {
    try await post("/v1/sessions/\(sessionID)/tasks/\(taskID)/checkpoint", body: request)
  }

  public func changeRole(
    sessionID: String,
    agentID: String,
    request: RoleChangeRequest
  ) async throws -> SessionDetail {
    try await post("/v1/sessions/\(sessionID)/agents/\(agentID)/role", body: request)
  }

  public func transferLeader(
    sessionID: String,
    request: LeaderTransferRequest
  ) async throws -> SessionDetail {
    try await post("/v1/sessions/\(sessionID)/leader", body: request)
  }

  public func endSession(
    sessionID: String,
    request: SessionEndRequest
  ) async throws -> SessionDetail {
    try await post("/v1/sessions/\(sessionID)/end", body: request)
  }

  public func sendSignal(
    sessionID: String,
    request: SignalSendRequest
  ) async throws -> SessionDetail {
    try await post("/v1/sessions/\(sessionID)/signal", body: request)
  }

  public func observeSession(sessionID: String) async throws -> SessionDetail {
    try await post("/v1/sessions/\(sessionID)/observe", body: EmptyRequest())
  }

  private func get<Response: Decodable>(_ path: String) async throws -> Response {
    var request = try makeRequest(path: path)
    request.httpMethod = "GET"
    return try await send(request)
  }

  private func post<RequestBody: Encodable, Response: Decodable>(
    _ path: String,
    body: RequestBody
  ) async throws -> Response {
    var request = try makeRequest(path: path)
    request.httpMethod = "POST"
    request.httpBody = try encoder.encode(AnyEncodable(body))
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return try await send(request)
  }

  private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw MonitorAPIError.invalidResponse
    }

    guard (200..<300).contains(httpResponse.statusCode) else {
      throw try decodeError(statusCode: httpResponse.statusCode, data: data)
    }

    return try decoder.decode(Response.self, from: data)
  }

  private func stream(_ path: String) -> AsyncThrowingStream<StreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let request = try makeRequest(path: path)
          let (bytes, response) = try await session.bytes(for: request)
          guard let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
          else {
            throw MonitorAPIError.invalidResponse
          }

          var parser = ServerSentEventParser()
          for try await line in bytes.lines {
            if let frame = parser.push(line: line) {
              let event = try decoder.decode(
                StreamEvent.self,
                from: Data(frame.data.utf8)
              )
              continuation.yield(event)
            }
          }

          if let frame = parser.finish() {
            let event = try decoder.decode(StreamEvent.self, from: Data(frame.data.utf8))
            continuation.yield(event)
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

  private func makeRequest(path: String) throws -> URLRequest {
    guard let url = URL(string: path, relativeTo: connection.endpoint) else {
      throw MonitorAPIError.invalidEndpoint(connection.endpoint.absoluteString)
    }

    var request = URLRequest(url: url)
    request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return request
  }

  private func decodeError(statusCode: Int, data: Data) throws -> MonitorAPIError {
    if let envelope = try? decoder.decode(ErrorEnvelope.self, from: data) {
      return .server(code: statusCode, message: envelope.error.message)
    }

    let message = String(data: data, encoding: .utf8) ?? "Unknown daemon error"
    return .server(code: statusCode, message: message)
  }
}

private struct EmptyRequest: Encodable {}

private struct AnyEncodable: Encodable {
  private let encodeClosure: (Encoder) throws -> Void

  init<Value: Encodable>(_ value: Value) {
    encodeClosure = value.encode(to:)
  }

  func encode(to encoder: Encoder) throws {
    try encodeClosure(encoder)
  }
}
