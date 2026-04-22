import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("WebSocket protocol wire format")
struct WebSocketProtocolTests {
  private actor RPCProbe {
    struct Call: Equatable, Sendable {
      let method: WebSocketRPCMethod
      let params: JSONValue?
    }

    private(set) var calls: [Call] = []

    func record(method: WebSocketRPCMethod, params: JSONValue?) {
      calls.append(Call(method: method, params: params))
    }

    func snapshot() -> [Call] { calls }
  }

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

  private func makeRPCTransport(
    handler: @escaping WebSocketTransport.RPCSender
  ) -> WebSocketTransport {
    let session = URLSession(configuration: .ephemeral)
    return WebSocketTransport(
      connection: HarnessMonitorConnection(
        endpoint: Self.testEndpoint,
        token: "test-token"
      ),
      session: session,
      rpcSender: handler
    )
  }

  private static func jsonValue<Value: Encodable>(_ value: Value) throws -> JSONValue {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let data = try encoder.encode(value)
    return try decoder.decode(JSONValue.self, from: data)
  }

  private func objectValue(_ value: JSONValue?, key: String) -> JSONValue? {
    guard case .object(let object)? = value else {
      return nil
    }
    return object[key]
  }

  private func sampleTerminalSnapshot(
    status: AgentTuiStatus = .running
  ) -> AgentTuiSnapshot {
    AgentTuiSnapshot(
      tuiId: "tui-1",
      sessionId: PreviewFixtures.summary.sessionId,
      agentId: "terminal-agent-1",
      runtime: "codex",
      status: status,
      argv: ["codex"],
      projectDir: PreviewFixtures.summary.projectDir ?? PreviewFixtures.summary.contextRoot,
      size: AgentTuiSize(rows: 24, cols: 80),
      screen: AgentTuiScreenSnapshot(
        rows: 24,
        cols: 80,
        cursorRow: 1,
        cursorCol: 1,
        text: "ready"
      ),
      transcriptPath: "/tmp/tui-1.log",
      exitCode: nil,
      signal: nil,
      error: nil,
      createdAt: "2026-04-22T10:00:00Z",
      updatedAt: "2026-04-22T10:00:01Z"
    )
  }

  private func sampleCodexSnapshot() -> CodexRunSnapshot {
    CodexRunSnapshot(
      runId: "codex-run-1",
      sessionId: PreviewFixtures.summary.sessionId,
      projectDir: PreviewFixtures.summary.projectDir ?? PreviewFixtures.summary.contextRoot,
      threadId: "thread-1",
      turnId: "turn-1",
      mode: .report,
      status: .running,
      prompt: "Investigate websocket parity",
      latestSummary: "running",
      finalMessage: nil,
      error: nil,
      pendingApprovals: [],
      createdAt: "2026-04-22T10:00:00Z",
      updatedAt: "2026-04-22T10:00:01Z"
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

    let expectedTraceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    #expect(traceContext?["traceparent"] == expectedTraceparent)
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

  @Test("WsFrame decodes parity error metadata")
  func errorDecodingWithParityMetadata() throws {
    let json = """
      {
        "id":"req-3",
        "error":{
          "code":"SESSION_ADOPT_FAILED",
          "message":"session already attached",
          "details":[],
          "status_code":409,
          "data":{"error":"already-attached","session_id":"sess-1"}
        }
      }
      """
    let frame = try decoder.decode(WsFrame.self, from: Data(json.utf8))
    guard case .response(let id, _, let error, _, _) = frame.kind else {
      Issue.record("Expected response frame kind, got \(frame.kind)")
      return
    }

    #expect(id == "req-3")
    let resolvedError = try #require(error)
    #expect(resolvedError.statusCode == 409)
    #expect(
      resolvedError.data
        == .object([
          "error": .string("already-attached"),
          "session_id": .string("sess-1"),
        ])
    )
  }

  @Test("WebSocket RPC catalog carries parity method names")
  func rpcCatalogRawValues() {
    #expect(WebSocketRPCMethod.bridgeReconfigure.rawValue == "bridge.reconfigure")
    #expect(WebSocketRPCMethod.sessionAdopt.rawValue == "session.adopt")
    #expect(WebSocketRPCMethod.managedAgentInput.rawValue == "managed_agent.input")
    #expect(WebSocketRPCMethod.voiceFinishSession.rawValue == "voice.finish_session")
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

  @Test("Agents list reads require a live WebSocket connection")
  func agentTuiListReadsRequireWebSocketConnection() async {
    let transport = makeTransport(endpoint: URL(string: "http://127.0.0.1:1")!)

    await #expect(throws: WebSocketTransportError.self) {
      let _: AgentTuiListResponse = try await transport.agentTuis(sessionID: "sess-1")
    }
  }

  @Test("Agents detail reads require a live WebSocket connection")
  func agentTuiDetailReadsRequireWebSocketConnection() async {
    let transport = makeTransport(endpoint: URL(string: "http://127.0.0.1:1")!)

    await #expect(throws: WebSocketTransportError.self) {
      let _: AgentTuiSnapshot = try await transport.agentTui(tuiID: "tui-1")
    }
  }

  @Test("WebSocket transport routes parity mutations over typed RPC methods")
  func parityMutationsUseTypedRPCMethods() async throws {
    let probe = RPCProbe()
    let terminalSnapshot = sampleTerminalSnapshot()
    let stoppedTerminalSnapshot = sampleTerminalSnapshot(status: .stopped)
    let codexSnapshot = sampleCodexSnapshot()
    let voiceMutation = VoiceSessionMutationResponse(
      voiceSessionId: "voice-1",
      status: "active"
    )
    let transport = makeRPCTransport { method, params, _ in
      await probe.record(method: method, params: params)
      switch method {
      case .bridgeReconfigure:
        return try Self.jsonValue(BridgeStatusReport(running: true, capabilities: [:]))
      case .sessionAdopt:
        return .object(["state": try Self.jsonValue(PreviewFixtures.summary)])
      case .managedAgentStartTerminal, .managedAgentInput, .managedAgentResize:
        return try Self.jsonValue(ManagedAgentSnapshot.terminal(terminalSnapshot))
      case .managedAgentStop:
        return try Self.jsonValue(ManagedAgentSnapshot.terminal(stoppedTerminalSnapshot))
      case .managedAgentStartCodex, .managedAgentSteerCodex,
        .managedAgentInterruptCodex, .managedAgentResolveCodexApproval:
        return try Self.jsonValue(ManagedAgentSnapshot.codex(codexSnapshot))
      case .voiceStartSession:
        return try Self.jsonValue(
          VoiceSessionStartResponse(
            voiceSessionId: "voice-1",
            acceptedSinks: [.localDaemon],
            status: "active"
          )
        )
      case .voiceAppendAudio, .voiceAppendTranscript, .voiceFinishSession:
        return try Self.jsonValue(voiceMutation)
      default:
        Issue.record("Unexpected RPC method \(method.rawValue)")
        throw HarnessMonitorAPIError.server(code: 500, message: "unexpected method")
      }
    }

    _ = try await transport.reconfigureHostBridge(
      request: HostBridgeReconfigureRequest(enable: ["codex"])
    )
    _ = try await transport.adoptSession(
      bookmarkID: "bookmark-1",
      sessionRoot: URL(fileURLWithPath: "/tmp/adopt")
    )
    _ = try await transport.startManagedTerminalAgent(
      sessionID: PreviewFixtures.summary.sessionId,
      request: AgentTuiStartRequest(
        runtime: "codex",
        projectDir: PreviewFixtures.summary.projectDir ?? PreviewFixtures.summary.contextRoot
      )
    )
    _ = try await transport.sendManagedAgentInput(
      agentID: terminalSnapshot.tuiId,
      request: AgentTuiInputRequest(input: .text("ls\n"))
    )
    _ = try await transport.resizeManagedAgent(
      agentID: terminalSnapshot.tuiId,
      request: AgentTuiResizeRequest(rows: 40, cols: 120)
    )
    _ = try await transport.stopManagedAgent(agentID: terminalSnapshot.tuiId)
    _ = try await transport.startManagedCodexAgent(
      sessionID: PreviewFixtures.summary.sessionId,
      request: CodexRunRequest(
        actor: "leader-1",
        prompt: "Investigate",
        mode: .report
      )
    )
    _ = try await transport.steerManagedCodexAgent(
      agentID: codexSnapshot.runId,
      request: CodexSteerRequest(prompt: "Continue")
    )
    _ = try await transport.interruptManagedCodexAgent(agentID: codexSnapshot.runId)
    _ = try await transport.resolveManagedCodexApproval(
      agentID: codexSnapshot.runId,
      approvalID: "approval-1",
      request: CodexApprovalDecisionRequest(decision: .accept)
    )
    _ = try await transport.startVoiceSession(
      sessionID: PreviewFixtures.summary.sessionId,
      request: VoiceSessionStartRequest(
        actor: "leader-1",
        localeIdentifier: "en_US",
        requestedSinks: [.localDaemon],
        routeTarget: .codexPrompt
      )
    )
    _ = try await transport.appendVoiceAudioChunk(
      voiceSessionID: "voice-1",
      request: VoiceAudioChunkRequest(
        actor: "leader-1",
        chunk: VoiceAudioChunk(
          sequence: 1,
          format: VoiceAudioFormatDescriptor(
            sampleRate: 16_000,
            channelCount: 1,
            commonFormat: "pcmFormatInt16",
            interleaved: false
          ),
          frameCount: 160,
          startedAtSeconds: 0,
          durationSeconds: 0.01,
          audioData: Data([0, 1, 2, 3])
        )
      )
    )
    _ = try await transport.appendVoiceTranscript(
      voiceSessionID: "voice-1",
      request: VoiceTranscriptUpdateRequest(
        actor: "leader-1",
        segment: VoiceTranscriptSegment(
          sequence: 2,
          text: "hello",
          isFinal: true,
          startedAtSeconds: 0,
          durationSeconds: 0.3
        )
      )
    )
    _ = try await transport.finishVoiceSession(
      voiceSessionID: "voice-1",
      request: VoiceSessionFinishRequest(
        actor: "leader-1",
        reason: .completed,
        confirmedText: "hello"
      )
    )

    let calls = await probe.snapshot()
    #expect(
      calls.map(\.method)
        == [
          .bridgeReconfigure,
          .sessionAdopt,
          .managedAgentStartTerminal,
          .managedAgentInput,
          .managedAgentResize,
          .managedAgentStop,
          .managedAgentStartCodex,
          .managedAgentSteerCodex,
          .managedAgentInterruptCodex,
          .managedAgentResolveCodexApproval,
          .voiceStartSession,
          .voiceAppendAudio,
          .voiceAppendTranscript,
          .voiceFinishSession,
        ]
    )
    #expect(objectValue(calls[0].params, key: "enable") == .array([.string("codex")]))
    #expect(objectValue(calls[1].params, key: "bookmark_id") == .string("bookmark-1"))
    #expect(
      objectValue(calls[2].params, key: "session_id") == .string(PreviewFixtures.summary.sessionId)
    )
    #expect(objectValue(calls[3].params, key: "agent_id") == .string(terminalSnapshot.tuiId))
    #expect(objectValue(calls[7].params, key: "agent_id") == .string(codexSnapshot.runId))
    #expect(
      objectValue(calls[10].params, key: "session_id")
        == .string(PreviewFixtures.summary.sessionId)
    )
    #expect(objectValue(calls[11].params, key: "voice_session_id") == .string("voice-1"))
  }

  @Test("WebSocket transport maps parity errors to HTTP-equivalent client errors")
  func parityErrorMappingMatchesHTTPSemantics() async throws {
    let transport = makeTransport()
    let adoptError = await transport.responseError(
      method: .sessionAdopt,
      error: WsErrorPayload(
        code: "SESSION_ADOPT_FAILED",
        message: "already attached",
        details: [],
        statusCode: 409,
        data: .object([
          "error": .string("already-attached"),
          "session_id": .string("sess-1"),
        ])
      )
    )
    let bridgeError = await transport.responseError(
      method: .bridgeReconfigure,
      error: WsErrorPayload(
        code: "BRIDGE_RECONFIGURE_FAILED",
        message: "bridge unavailable",
        details: [],
        statusCode: 503,
        data: .object([
          "error": .object([
            "code": .string("bridge_unavailable"),
            "message": .string("bridge unavailable"),
            "details": .array([]),
          ])
        ])
      )
    )

    #expect(adoptError as? HarnessMonitorAPIError == .adoptAlreadyAttached(sessionId: "sess-1"))
    #expect(
      bridgeError as? HarnessMonitorAPIError
        == .server(code: 503, message: "bridge unavailable")
    )
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
}
