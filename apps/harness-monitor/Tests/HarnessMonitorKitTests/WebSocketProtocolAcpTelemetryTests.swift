import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("WebSocket ACP turn telemetry wire format")
struct WebSocketProtocolAcpTelemetryTests {
  private let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }()

  @Test("Daemon push event decodes ACP turn telemetry rows")
  func daemonPushEventDecodesAcpTurnTelemetryRows() throws {
    let json = """
      {
        "event": "acp_events",
        "session_id": "session-1",
        "recorded_at": "2026-07-20T00:00:30Z",
        "payload": {
          "managed_agent_id": "acp-1",
          "managed_agent_family": "acp",
          "session_id": "session-1",
          "raw_count": 3,
          "events": [
            {
              "timestamp": "2026-07-20T00:00:00Z",
              "sequence": 1,
              "agent": "copilot",
              "session_id": "session-1",
              "kind": {
                "type": "context_usage",
                "used_tokens": 53000,
                "context_window_tokens": 200000,
                "cost_amount": 0.045,
                "cost_currency": "USD"
              }
            },
            {
              "timestamp": "2026-07-20T00:00:01Z",
              "sequence": 2,
              "agent": "copilot",
              "session_id": "session-1",
              "kind": {
                "type": "context_usage",
                "used_tokens": 10,
                "context_window_tokens": 100
              }
            },
            {
              "timestamp": "2026-07-20T00:00:02Z",
              "sequence": 3,
              "agent": "copilot",
              "session_id": "session-1",
              "kind": {
                "type": "turn_ended",
                "stop_reason": "refusal"
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
    #expect(
      entries.map(\.kind) == [
        "agent_context_usage",
        "agent_context_usage",
        "agent_turn_ended",
      ]
    )
    #expect(entries[0].summary == "copilot used 53000 of 200000 context tokens (0.045 USD)")
    #expect(entries[1].summary == "copilot used 10 of 100 context tokens")
    #expect(entries[2].summary == "copilot refused to continue the turn")
    #expect(entries[2].entryId == "acp-copilot-agent_turn_ended-3")
  }

  @Test("Daemon push event decodes ACP message ids on transcript chunks")
  func daemonPushEventDecodesAcpMessageIds() throws {
    let json = """
      {
        "event": "acp_events",
        "session_id": "session-1",
        "recorded_at": "2026-07-20T00:01:30Z",
        "payload": {
          "managed_agent_id": "acp-1",
          "managed_agent_family": "acp",
          "session_id": "session-1",
          "raw_count": 1,
          "events": [
            {
              "timestamp": "2026-07-20T00:01:00Z",
              "sequence": 1,
              "agent": "copilot",
              "session_id": "session-1",
              "kind": {
                "type": "assistant_text",
                "content": "partial answer",
                "message_id": "msg-7"
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
    #expect(entries.map(\.kind) == ["assistant_text"])
    #expect(entries[0].summary == "partial answer")
    guard case .object(let payloadObject) = entries[0].payload,
      case .object(let kindObject)? = payloadObject["event"]
    else {
      Issue.record("Expected assistant_text payload object")
      return
    }
    #expect(kindObject["message_id"] == .string("msg-7"))
  }
}
