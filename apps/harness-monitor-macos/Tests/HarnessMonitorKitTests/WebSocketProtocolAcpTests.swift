import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("WebSocket ACP protocol wire format")
struct WebSocketProtocolAcpTests {
  private let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }()

  @Test("Daemon push event decodes ACP permission request")
  func daemonPushEventDecodesAcpPermissionRequest() throws {
    let json = """
      {
        "event": "acp_permission_requested",
        "session_id": "session-1",
        "recorded_at": "2026-04-28T00:00:00Z",
        "payload": {
          "batch_id": "batch-1",
          "acp_id": "acp-1",
          "session_id": "session-1",
          "created_at": "2026-04-28T00:00:00Z",
          "requests": [
            {
              "request_id": "request-1",
              "session_id": "session-1",
              "tool_call": { "name": "write_file", "path": "src/lib.rs" },
              "options": []
            }
          ]
        }
      }
      """
    let streamEvent = try decoder.decode(StreamEvent.self, from: Data(json.utf8))
    let event = try DaemonPushEvent(streamEvent: streamEvent)
    guard case .acpPermissionBatch(let batch) = event.kind else {
      Issue.record("Expected ACP permission batch, got \(event.kind)")
      return
    }
    #expect(batch.batchId == "batch-1")
    #expect(batch.requests.first?.requestId == "request-1")
  }

  @Test("Daemon push event decodes ACP events into timeline entries")
  func daemonPushEventDecodesAcpEventsIntoTimelineEntries() throws {
    let json = """
      {
        "event": "acp_events",
        "session_id": "session-1",
        "recorded_at": "2026-04-28T00:00:30Z",
        "payload": {
          "acp_id": "acp-1",
          "session_id": "session-1",
          "raw_count": 2,
          "events": [
            {
              "timestamp": "2026-04-28T00:00:00Z",
              "sequence": 7,
              "agent": "copilot",
              "session_id": "session-1",
              "kind": {
                "type": "tool_invocation",
                "tool_name": "Write",
                "category": "edit",
                "input": { "path": "src/lib.rs" },
                "invocation_id": "call-1"
              }
            },
            {
              "timestamp": "2026-04-28T00:00:05Z",
              "sequence": 8,
              "agent": "copilot",
              "session_id": "session-1",
              "kind": {
                "type": "tool_result",
                "tool_name": "Write",
                "invocation_id": "call-1",
                "output": "ok",
                "is_error": false
              }
            }
          ]
        }
      }
      """
    let streamEvent = try decoder.decode(StreamEvent.self, from: Data(json.utf8))
    let event = try DaemonPushEvent(streamEvent: streamEvent)
    guard case .acpEvents(let payload) = event.kind else {
      Issue.record("Expected ACP events, got \(event.kind)")
      return
    }
    let entries = payload.timelineEntries(fallbackRecordedAt: event.recordedAt)

    #expect(payload.acpId == "acp-1")
    #expect(payload.rawCount == 2)
    #expect(entries.map(\.kind) == ["tool_invocation", "tool_result"])
    #expect(entries[0].entryId == "acp-copilot-tool_invocation-7")
    #expect(
      entries[1].payload
        == .object([
          "runtime": .string("acp"),
          "event": .object([
            "type": .string("tool_result"),
            "tool_name": .string("Write"),
            "invocation_id": .string("call-1"),
            "output": .string("ok"),
            "is_error": .bool(false),
          ]),
        ])
    )
  }
}
