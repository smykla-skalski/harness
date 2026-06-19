import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract regression for the acp_events broadcast push frame. Generated from
/// daemon/agent_acp/event_frame.rs (the new daemon-side serde frame) + agents/runtime/event.rs; the
/// conversation event's richly-tagged kind rides through opaque as JSONValue, and the batch map
/// enforces the managed_agent_family == acp contract the hand requireAcpManagedAgentFamily used to.
@Suite("ACP event batch wire decoding")
struct AcpEventBatchWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("maps the managed-agent envelope and the opaque-kind conversation events")
  func batchMapping() throws {
    let payload = #"""
      {
        "managed_agent_id": "acp-1",
        "managed_agent_family": "acp",
        "session_id": "sess-1",
        "raw_count": 2,
        "events": [
          {"timestamp": "2026-06-18T00:00:00Z", "sequence": 1,
           "kind": {"type": "assistant_text", "content": "hi"}, "agent": "a", "session_id": "sess-1"},
          {"sequence": 2, "kind": {"type": "tool_invocation", "tool_name": "ls"},
           "agent": "a", "session_id": "sess-1"}
        ]
      }
      """#
    let data = try #require(payload.data(using: .utf8))
    let wire = try decoder.decode(AcpEventBatchPayloadWire.self, from: data)
    let batch = try AcpEventBatchPayload(wire: wire)

    #expect(batch.acpId == "acp-1")
    #expect(batch.sessionId == "sess-1")
    #expect(batch.rawCount == 2)
    #expect(batch.events.count == 2)
    #expect(batch.events.first?.sequence == 1)
    #expect(batch.events.first?.timestamp == "2026-06-18T00:00:00Z")
    #expect(batch.events.last?.timestamp == nil)
    if case .object(let kind) = batch.events.first?.kind {
      #expect(kind["type"] == .string("assistant_text"))
      #expect(kind["content"] == .string("hi"))
    } else {
      Issue.record("expected the conversation event kind to ride through as a JSON object")
    }
  }

  @Test("rejects a non-acp managed agent family")
  func rejectsWrongFamily() throws {
    let payload = #"""
      {"managed_agent_id": "x", "managed_agent_family": "tui", "session_id": "s",
       "raw_count": 0, "events": []}
      """#
    let data = try #require(payload.data(using: .utf8))
    let wire = try decoder.decode(AcpEventBatchPayloadWire.self, from: data)
    #expect(throws: DecodingError.self) {
      _ = try AcpEventBatchPayload(wire: wire)
    }
  }
}
