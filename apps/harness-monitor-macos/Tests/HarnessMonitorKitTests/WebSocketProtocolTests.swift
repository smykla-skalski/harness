import Foundation
import Testing

@testable import HarnessMonitorKit

extension WebSocketTransport {
  func installTestGlobalStreamContinuation(
    _ continuation: AsyncThrowingStream<DaemonPushEvent, Error>.Continuation
  ) {
    globalStreamContinuation = continuation
  }

  func installTestSessionStreamContinuation(
    _ continuation: AsyncThrowingStream<DaemonPushEvent, Error>.Continuation,
    sessionID: String
  ) {
    sessionStreamContinuations[sessionID] = continuation
  }

  func hasTestGlobalStreamContinuation() -> Bool {
    globalStreamContinuation != nil
  }

  func hasTestSessionStreamContinuation(sessionID: String) -> Bool {
    sessionStreamContinuations[sessionID] != nil
  }

  func installTestGlobalSubscriptionActive(_ active: Bool) {
    globalSubscriptionActive = active
  }
}

@Suite("WebSocket protocol wire format")
struct WebSocketProtocolTests {
  private static let testEndpoint: URL = {
    guard let url = URL(string: "http://127.0.0.1:8080") else {
      preconditionFailure("Invalid test endpoint URL literal")
    }
    return url
  }()

  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return encoder
  }()

  private let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }()

  private func makeTransport(
    endpoint: URL = Self.testEndpoint
  ) -> WebSocketTransport {
    WebSocketTransport(
      connection: HarnessMonitorConnection(
        endpoint: endpoint,
        token: "test-token"
      )
    )
  }

  @Test("WsRequest encodes with snake_case keys")
  func requestEncoding() throws {
    let request = WsRequest(
      id: "abc-123",
      method: "session.detail",
      params: .object(["session_id": .string("sess-1")])
    )
    let data = try encoder.encode(request)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(json?["id"] as? String == "abc-123")
    #expect(json?["method"] as? String == "session.detail")
  }

  @Test("WsRequest encodes trace_context when present")
  func requestEncodingWithTraceContext() throws {
    let request = WsRequest(
      id: "trace-123",
      method: "session.detail",
      params: .object(["session_id": .string("sess-1")]),
      traceContext: [
        "traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
      ]
    )
    let data = try encoder.encode(request)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let traceContext = json?["trace_context"] as? [String: String]

    #expect(traceContext?["traceparent"] == "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")
  }

  @Test("WsRequest decodes without trace_context")
  func requestDecodingWithoutTraceContext() throws {
    let json = """
      {"id":"req-1","method":"stream.subscribe","params":{"scope":"global"}}
      """
    let request = try decoder.decode(WsRequest.self, from: Data(json.utf8))

    #expect(request.traceContext == nil)
  }

  @Test("Telemetry trace context produces a websocket traceparent")
  func telemetryTraceContextProducesWebSocketTraceparent() throws {
    HarnessMonitorTelemetry.shared.resetForTests()
    defer { HarnessMonitorTelemetry.shared.resetForTests() }

    let span = HarnessMonitorTelemetry.shared.startSpan(
      name: "daemon.websocket.rpc",
      kind: .client
    )
    defer { span.end() }

    let traceContext = HarnessMonitorTelemetry.shared.traceContext(spanContext: span.context)
    #expect(traceContext["traceparent"]?.isEmpty == false)

    let request = WsRequest(
      id: "trace-ctx",
      method: "session.detail",
      params: .object(["session_id": .string("sess-1")]),
      traceContext: traceContext
    )
    let data = try encoder.encode(request)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let encodedTraceContext = json?["trace_context"] as? [String: String]

    #expect(encodedTraceContext?["traceparent"]?.isEmpty == false)
  }

  @Test("WebSocket transport request carries trace_context from span context")
  func transportRequestCarriesTraceContext() async {
    HarnessMonitorTelemetry.shared.resetForTests()
    defer { HarnessMonitorTelemetry.shared.resetForTests() }

    let transport = makeTransport()
    let span = HarnessMonitorTelemetry.shared.startSpan(
      name: "daemon.websocket.rpc",
      kind: .client
    )
    defer { span.end() }

    let request = await transport.makeRequest(
      id: "trace-rpc-1",
      method: "session.detail",
      params: .object(["session_id": .string("sess-1")]),
      spanContext: span.context
    )

    #expect(request.traceContext?["traceparent"]?.isEmpty == false)
  }

  @Test("WsFrame decodes response with result")
  func responseDecoding() throws {
    let json = """
      {"id":"req-1","result":{"status":"ok"},"error":null}
      """
    let frame = try decoder.decode(WsFrame.self, from: Data(json.utf8))
    guard case .response(let id, let result, let error, let batchIndex, let batchCount) = frame.kind
    else {
      Issue.record("Expected response frame kind, got \(frame.kind)")
      return
    }
    #expect(id == "req-1")
    #expect(result != nil)
    #expect(error == nil)
    #expect(batchIndex == nil)
    #expect(batchCount == nil)
  }

  @Test("WsFrame decodes response with error")
  func errorDecoding() throws {
    let json = """
      {"id":"req-2","result":null,"error":{"code":"NOT_FOUND","message":"session not found","details":[]}}
      """
    let frame = try decoder.decode(WsFrame.self, from: Data(json.utf8))
    guard case .response(let id, _, let error, let batchIndex, let batchCount) = frame.kind else {
      Issue.record("Expected response frame kind, got \(frame.kind)")
      return
    }
    #expect(id == "req-2")
    let resolvedError = try #require(error)
    #expect(resolvedError.code == "NOT_FOUND")
    #expect(resolvedError.message == "session not found")
    #expect(batchIndex == nil)
    #expect(batchCount == nil)
  }

  @Test("WsFrame decodes semantic response batch metadata")
  func responseBatchDecoding() throws {
    let json = """
      {
        "id":"req-batch",
        "batch_index":1,
        "batch_count":3,
        "result":[{"entry_id":"entry-1","summary":"hello"}]
      }
      """
    let frame = try decoder.decode(WsFrame.self, from: Data(json.utf8))
    guard case .response(let id, let result, let error, let batchIndex, let batchCount) = frame.kind
    else {
      Issue.record("Expected response batch frame kind, got \(frame.kind)")
      return
    }

    #expect(id == "req-batch")
    #expect(error == nil)
    #expect(batchIndex == 1)
    #expect(batchCount == 3)
    guard let resolvedResult = result else {
      Issue.record("Expected response batch array payload, got nil")
      return
    }
    guard case .array(let entries) = resolvedResult else {
      Issue.record("Expected response batch array payload, got \(String(describing: result))")
      return
    }
    #expect(entries.count == 1)
  }

  @Test("WsFrame decodes push event")
  func pushEventDecoding() throws {
    let json = """
      {"event":"session_updated","recorded_at":"2026-03-29T12:00:00Z",\
      "session_id":"sess-1","payload":{},"seq":42}
      """
    let frame = try decoder.decode(WsFrame.self, from: Data(json.utf8))
    guard case .push(let event, _, let sessionId, _, let seq) = frame.kind else {
      Issue.record("Expected push frame kind, got \(frame.kind)")
      return
    }
    #expect(event == "session_updated")
    #expect(sessionId == "sess-1")
    #expect(seq == 42)
  }

  @Test("Malformed push frames do not terminate active streams")
  func malformedPushFramesDoNotTerminateActiveStreams() async throws {
    let transport = makeTransport()
    let sessionID = "sess-1"
    let (globalStream, globalContinuation) = AsyncThrowingStream<DaemonPushEvent, Error>
      .makeStream()
    let (sessionStream, sessionContinuation) = AsyncThrowingStream<DaemonPushEvent, Error>
      .makeStream()

    await transport.installTestGlobalStreamContinuation(globalContinuation)
    await transport.installTestSessionStreamContinuation(sessionContinuation, sessionID: sessionID)

    let malformedFrame = WsFrame(
      id: nil,
      result: nil,
      error: nil,
      batchIndex: nil,
      batchCount: nil,
      event: "session_updated",
      recordedAt: "2026-04-13T17:30:00Z",
      sessionId: nil,
      payload: .object([:]),
      seq: 1,
      chunkId: nil,
      chunkIndex: nil,
      chunkCount: nil,
      chunkBase64: nil
    )
    try await transport.handleFrame(malformedFrame)

    #expect(await transport.hasTestGlobalStreamContinuation())
    #expect(await transport.hasTestSessionStreamContinuation(sessionID: sessionID))

    let validFrame = WsFrame(
      id: nil,
      result: nil,
      error: nil,
      batchIndex: nil,
      batchCount: nil,
      event: "mystery_event",
      recordedAt: "2026-04-13T17:31:00Z",
      sessionId: sessionID,
      payload: .object(["ok": .bool(true)]),
      seq: 2,
      chunkId: nil,
      chunkIndex: nil,
      chunkCount: nil,
      chunkBase64: nil
    )
    try await transport.handleFrame(validFrame)

    var globalIterator = globalStream.makeAsyncIterator()
    let globalEvent = try await #require(globalIterator.next())
    if case .unknown(let eventName, let payload) = globalEvent.kind {
      #expect(eventName == "mystery_event")
      #expect(payload == .object(["ok": .bool(true)]))
    } else {
      Issue.record("expected unknown global push event after malformed frame")
    }

    var sessionIterator = sessionStream.makeAsyncIterator()
    let sessionEvent = try await #require(sessionIterator.next())
    if case .unknown(let eventName, let payload) = sessionEvent.kind {
      #expect(eventName == "mystery_event")
      #expect(payload == .object(["ok": .bool(true)]))
    } else {
      Issue.record("expected unknown session push event after malformed frame")
    }
  }

  @Test("Reconnect ready events reach active global and session streams")
  func reconnectReadyEventsReachActiveStreams() async throws {
    let transport = makeTransport()
    let sessionID = "sess-reconnect-ready"
    let (globalStream, globalContinuation) = AsyncThrowingStream<DaemonPushEvent, Error>
      .makeStream()
    let (sessionStream, sessionContinuation) = AsyncThrowingStream<DaemonPushEvent, Error>
      .makeStream()

    await transport.installTestGlobalStreamContinuation(globalContinuation)
    await transport.installTestSessionStreamContinuation(sessionContinuation, sessionID: sessionID)
    await transport.installTestGlobalSubscriptionActive(true)

    await transport.emitReconnectReadyEvents()

    var globalIterator = globalStream.makeAsyncIterator()
    let globalEvent = try await #require(globalIterator.next())
    if case .ready = globalEvent.kind {
      #expect(globalEvent.sessionId == nil)
    } else {
      Issue.record("expected reconnect-ready global event")
    }

    var sessionIterator = sessionStream.makeAsyncIterator()
    let sessionEvent = try await #require(sessionIterator.next())
    if case .ready = sessionEvent.kind {
      #expect(sessionEvent.sessionId == sessionID)
    } else {
      Issue.record("expected reconnect-ready session event")
    }
  }

  @Test("Agent TUI list reads require a live WebSocket connection")
  func agentTuiListReadsRequireWebSocketConnection() async {
    let transport = makeTransport(endpoint: URL(string: "http://127.0.0.1:1")!)

    await #expect(throws: WebSocketTransportError.self) {
      let _: AgentTuiListResponse = try await transport.agentTuis(sessionID: "sess-1")
    }
  }

  @Test("Agent TUI detail reads require a live WebSocket connection")
  func agentTuiDetailReadsRequireWebSocketConnection() async {
    let transport = makeTransport(endpoint: URL(string: "http://127.0.0.1:1")!)

    await #expect(throws: WebSocketTransportError.self) {
      let _: AgentTuiSnapshot = try await transport.agentTui(tuiID: "tui-1")
    }
  }

  @Test("WsFrame returns unknown for empty object")
  func unknownFrame() throws {
    let json = "{}"
    let frame = try decoder.decode(WsFrame.self, from: Data(json.utf8))
    guard case .unknown = frame.kind else {
      Issue.record("Expected unknown frame kind, got \(frame.kind)")
      return
    }
  }

  @Test("WsFrame decodes chunk frame metadata")
  func chunkFrameDecoding() throws {
    let json = """
      {
        "chunk_id":"response:req-1",
        "chunk_index":0,
        "chunk_count":2,
        "chunk_base64":"e30="
      }
      """
    let frame = try decoder.decode(WsFrame.self, from: Data(json.utf8))
    guard case .chunk(let chunkID, let chunkIndex, let chunkCount, let chunkBase64) = frame.kind
    else {
      Issue.record("Expected chunk frame kind, got \(frame.kind)")
      return
    }

    #expect(chunkID == "response:req-1")
    #expect(chunkIndex == 0)
    #expect(chunkCount == 2)
    #expect(chunkBase64 == "e30=")
  }

  @Test("SessionUpdatedPayload decodes when timeline is omitted")
  func sessionUpdatedPayloadWithoutTimeline() throws {
    let json = """
      {
        "detail": {
          "session": {
            "project_id": "project-1",
            "project_name": "Harness",
            "project_dir": "/tmp/harness",
            "context_root": "/tmp/context",
            "session_id": "sess-1",
            "context": "Demo session",
            "status": "active",
            "created_at": "2026-03-29T12:00:00Z",
            "updated_at": "2026-03-29T12:00:00Z",
            "last_activity_at": "2026-03-29T12:00:00Z",
            "leader_id": "leader-1",
            "observe_id": null,
            "pending_leader_transfer": null,
            "metrics": {
              "agent_count": 1,
              "active_agent_count": 1,
              "open_task_count": 0,
              "in_progress_task_count": 0,
              "blocked_task_count": 0,
              "completed_task_count": 0
            }
          },
          "agents": [],
          "tasks": [],
          "signals": [],
          "observer": null,
          "agent_activity": []
        }
      }
      """
    let payload = try decoder.decode(SessionUpdatedPayload.self, from: Data(json.utf8))

    #expect(payload.detail.session.sessionId == "sess-1")
    #expect(payload.timeline == nil)
  }

  @Test("PendingRequestStore resume delivers result")
  func pendingStoreResume() async throws {
    let store = PendingRequestStore()
    let result: JSONValue = try await withCheckedThrowingContinuation { continuation in
      store.register(id: "test-1", continuation: continuation)
      store.resume(id: "test-1", result: .string("hello"))
    }
    #expect(result == .string("hello"))
  }

  @Test("PendingRequestStore fail delivers error")
  func pendingStoreFail() async throws {
    let store = PendingRequestStore()
    await #expect(throws: WebSocketTransportError.self) {
      let _: JSONValue =
        try await withCheckedThrowingContinuation { continuation in
          store.register(id: "test-2", continuation: continuation)
          store.fail(
            id: "test-2",
            error: WebSocketTransportError.connectionClosed
          )
        }
    }
  }

  @Test("PendingRequestStore assembles semantic response batches")
  func pendingStoreResumeBatch() async throws {
    let store = PendingRequestStore()
    let result: JSONValue = try await withCheckedThrowingContinuation { continuation in
      store.register(id: "batched", continuation: continuation)
      _ = try? store.resumeBatch(
        id: "batched",
        index: 1,
        count: 2,
        result: .array([.string("beta")])
      )
      _ = try? store.resumeBatch(
        id: "batched",
        index: 0,
        count: 2,
        result: .array([.string("alpha")])
      )
    }

    #expect(result == .array([.string("alpha"), .string("beta")]))
  }

  @Test("PendingRequestStore failAll clears all pending")
  func pendingStoreFailAll() async throws {
    let store = PendingRequestStore()
    await #expect(throws: WebSocketTransportError.self) {
      let _: JSONValue = try await withCheckedThrowingContinuation { continuation in
        store.register(id: "a", continuation: continuation)
        store.failAll(error: WebSocketTransportError.connectionClosed)
      }
    }
  }
}
