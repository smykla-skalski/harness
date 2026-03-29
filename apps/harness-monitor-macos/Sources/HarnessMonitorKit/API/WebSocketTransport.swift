import Foundation

public final class WebSocketTransport: MonitorClientProtocol, @unchecked Sendable {
  private let connection: MonitorConnection
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  private let session: URLSession
  private let pending = PendingRequestStore()
  private var webSocketTask: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var heartbeatTask: Task<Void, Never>?
  private var globalStreamContinuation: AsyncThrowingStream<StreamEvent, Error>.Continuation?
  private var sessionStreamContinuations:
    [String: AsyncThrowingStream<StreamEvent, Error>.Continuation] = [:]
  private let lock = NSLock()

  public init(connection: MonitorConnection) {
    self.connection = connection
    encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    session = URLSession(configuration: .default)
  }

  public func connect() async throws {
    let wsURL = wsEndpoint()
    var request = URLRequest(url: wsURL)
    request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
    let task = session.webSocketTask(with: request)
    webSocketTask = task
    task.resume()
    startReceiveLoop()
    startHeartbeat()
  }

  public func disconnect() {
    receiveTask?.cancel()
    heartbeatTask?.cancel()
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    webSocketTask = nil
    pending.failAll(error: WebSocketTransportError.connectionClosed)
    terminateAllStreams()
  }
}

extension WebSocketTransport {
  // MARK: - MonitorClientProtocol queries

  public func health() async throws -> HealthResponse {
    let value = try await send(method: "health")
    return try decode(value)
  }

  public func diagnostics() async throws -> DaemonDiagnosticsReport {
    let value = try await send(method: "diagnostics")
    return try decode(value)
  }

  public func projects() async throws -> [ProjectSummary] {
    let value = try await send(method: "projects")
    return try decode(value)
  }

  public func sessions() async throws -> [SessionSummary] {
    let value = try await send(method: "sessions")
    return try decode(value)
  }

  public func sessionDetail(id: String) async throws -> SessionDetail {
    let value = try await send(
      method: "session.detail",
      params: .object(["session_id": .string(id)])
    )
    return try decode(value)
  }

  public func timeline(sessionID: String) async throws -> [TimelineEntry] {
    let value = try await send(
      method: "session.timeline",
      params: .object(["session_id": .string(sessionID)])
    )
    return try decode(value)
  }
}

extension WebSocketTransport {
  // MARK: - Streams

  public func globalStream() -> AsyncThrowingStream<StreamEvent, Error> {
    AsyncThrowingStream { continuation in
      lock.withLock { globalStreamContinuation = continuation }
      continuation.onTermination = { [weak self] _ in
        guard let self else { return }
        self.lock.withLock { self.globalStreamContinuation = nil }
        Task {
          try? await self.send(
            method: "stream.unsubscribe",
            params: .object(["scope": .string("global")])
          )
        }
      }
      Task {
        do {
          _ = try await self.send(
            method: "stream.subscribe",
            params: .object(["scope": .string("global")])
          )
        } catch {
          continuation.finish(throwing: error)
        }
      }
    }
  }

  public func sessionStream(sessionID: String) -> AsyncThrowingStream<StreamEvent, Error> {
    AsyncThrowingStream { continuation in
      lock.withLock { sessionStreamContinuations[sessionID] = continuation }
      continuation.onTermination = { [weak self] _ in
        guard let self else { return }
        self.lock.withLock { self.sessionStreamContinuations[sessionID] = nil }
        Task {
          try? await self.send(
            method: "session.unsubscribe",
            params: .object(["session_id": .string(sessionID)])
          )
        }
      }
      Task {
        do {
          _ = try await self.send(
            method: "session.subscribe",
            params: .object(["session_id": .string(sessionID)])
          )
        } catch {
          continuation.finish(throwing: error)
        }
      }
    }
  }
}

extension WebSocketTransport {
  // MARK: - Mutations

  public func createTask(
    sessionID: String,
    request: TaskCreateRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(request, extra: ["session_id": .string(sessionID)])
    let value = try await send(method: "task.create", params: params)
    return try decode(value)
  }

  public func assignTask(
    sessionID: String,
    taskID: String,
    request: TaskAssignRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(
      request,
      extra: ["session_id": .string(sessionID), "task_id": .string(taskID)]
    )
    let value = try await send(method: "task.assign", params: params)
    return try decode(value)
  }

  public func updateTask(
    sessionID: String,
    taskID: String,
    request: TaskUpdateRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(
      request,
      extra: ["session_id": .string(sessionID), "task_id": .string(taskID)]
    )
    let value = try await send(method: "task.update", params: params)
    return try decode(value)
  }

  public func checkpointTask(
    sessionID: String,
    taskID: String,
    request: TaskCheckpointRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(
      request,
      extra: ["session_id": .string(sessionID), "task_id": .string(taskID)]
    )
    let value = try await send(method: "task.checkpoint", params: params)
    return try decode(value)
  }

  public func changeRole(
    sessionID: String,
    agentID: String,
    request: RoleChangeRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(
      request,
      extra: ["session_id": .string(sessionID), "agent_id": .string(agentID)]
    )
    let value = try await send(method: "agent.change_role", params: params)
    return try decode(value)
  }

  public func removeAgent(
    sessionID: String,
    agentID: String,
    request: AgentRemoveRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(
      request,
      extra: ["session_id": .string(sessionID), "agent_id": .string(agentID)]
    )
    let value = try await send(method: "agent.remove", params: params)
    return try decode(value)
  }

  public func transferLeader(
    sessionID: String,
    request: LeaderTransferRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(request, extra: ["session_id": .string(sessionID)])
    let value = try await send(method: "leader.transfer", params: params)
    return try decode(value)
  }

  public func endSession(
    sessionID: String,
    request: SessionEndRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(request, extra: ["session_id": .string(sessionID)])
    let value = try await send(method: "session.end", params: params)
    return try decode(value)
  }

  public func sendSignal(
    sessionID: String,
    request: SignalSendRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(request, extra: ["session_id": .string(sessionID)])
    let value = try await send(method: "signal.send", params: params)
    return try decode(value)
  }

  public func observeSession(
    sessionID: String,
    request: ObserveSessionRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(request, extra: ["session_id": .string(sessionID)])
    let value = try await send(method: "session.observe", params: params)
    return try decode(value)
  }
}

// MARK: - Internal transport mechanics

extension WebSocketTransport {
  @discardableResult
  func send(method: String, params: JSONValue? = nil) async throws -> JSONValue {
    guard let webSocketTask else {
      throw WebSocketTransportError.connectionClosed
    }
    let id = UUID().uuidString
    let request = WsRequest(id: id, method: method, params: params)
    let data = try encoder.encode(request)
    let text = String(data: data, encoding: .utf8) ?? "{}"
    return try await withCheckedThrowingContinuation { continuation in
      pending.register(id: id, continuation: continuation)
      webSocketTask.send(.string(text)) { [weak self] error in
        if let error {
          self?.pending.fail(id: id, error: error)
        }
      }
    }
  }

  func startReceiveLoop() {
    receiveTask?.cancel()
    receiveTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        guard let webSocketTask = self.webSocketTask else { break }
        do {
          let message = try await webSocketTask.receive()
          self.handleMessage(message)
        } catch {
          if !Task.isCancelled {
            self.pending.failAll(error: error)
            self.terminateAllStreams()
          }
          break
        }
      }
    }
  }

  func handleMessage(_ message: URLSessionWebSocketTask.Message) {
    guard case .string(let text) = message else { return }
    guard let data = text.data(using: .utf8) else { return }
    guard let frame = try? decoder.decode(WsFrame.self, from: data) else { return }

    switch frame.kind {
    case .response(let id, let result, let error):
      if let error {
        pending.fail(
          id: id,
          error: WebSocketTransportError.serverError(code: error.code, message: error.message)
        )
      } else if let result {
        pending.resume(id: id, result: result)
      } else {
        pending.resume(id: id, result: .null)
      }

    case .push(let event, let recordedAt, let sessionId, let payload, _):
      let streamEvent = StreamEvent(
        event: event,
        recordedAt: recordedAt,
        sessionId: sessionId,
        payload: payload
      )
      lock.withLock {
        globalStreamContinuation?.yield(streamEvent)
        if let sessionId, let continuation = sessionStreamContinuations[sessionId] {
          continuation.yield(streamEvent)
        }
      }

    case .unknown:
      break
    }
  }

  func startHeartbeat() {
    heartbeatTask?.cancel()
    heartbeatTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(15))
        guard !Task.isCancelled, let self else { break }
        _ = try? await self.send(method: "ping")
      }
    }
  }

  func terminateAllStreams() {
    lock.withLock {
      globalStreamContinuation?.finish()
      globalStreamContinuation = nil
      for (_, continuation) in sessionStreamContinuations {
        continuation.finish()
      }
      sessionStreamContinuations.removeAll()
    }
  }

  func wsEndpoint() -> URL {
    var components = URLComponents(url: connection.endpoint, resolvingAgainstBaseURL: false)!
    components.scheme = connection.endpoint.scheme == "https" ? "wss" : "ws"
    components.path = "/v1/ws"
    return components.url!
  }

  func decode<T: Decodable>(_ value: JSONValue) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try decoder.decode(T.self, from: data)
  }

  func encodeParams<T: Encodable>(
    _ body: T,
    extra: [String: JSONValue]
  ) throws -> JSONValue {
    let data = try encoder.encode(body)
    guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return .null
    }
    for (key, value) in extra {
      if case .string(let stringValue) = value {
        object[key] = stringValue
      }
    }
    let merged = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(JSONValue.self, from: merged)
  }
}
