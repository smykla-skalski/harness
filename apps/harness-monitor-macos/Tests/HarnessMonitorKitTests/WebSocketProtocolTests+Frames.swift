import Foundation
import Testing

@testable import HarnessMonitorKit

extension WebSocketProtocolTests {
  @Test("Agents list reads require a live WebSocket connection")
  func agentTuiListReadsRequireWebSocketConnection() async {
    guard let endpoint = URL(string: "http://127.0.0.1:1") else {
      Issue.record("Invalid endpoint literal")
      return
    }
    let transport = makeTransport(endpoint: endpoint)

    await #expect(throws: WebSocketTransportError.self) {
      let _: AgentTuiListResponse = try await transport.agentTuis(sessionID: "sess-1")
    }
  }

  @Test("Agents detail reads require a live WebSocket connection")
  func agentTuiDetailReadsRequireWebSocketConnection() async {
    guard let endpoint = URL(string: "http://127.0.0.1:1") else {
      Issue.record("Invalid endpoint literal")
      return
    }
    let transport = makeTransport(endpoint: endpoint)

    await #expect(throws: WebSocketTransportError.self) {
      let _: AgentTuiSnapshot = try await transport.agentTui(tuiID: "tui-1")
    }
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
