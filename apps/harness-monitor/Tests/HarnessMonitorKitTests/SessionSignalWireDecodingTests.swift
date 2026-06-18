import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract regression for SessionDetail.signals (SessionSignalRecord). The signal wire
/// types are generated from the Rust runtime signal cluster + events.rs by
/// examples/policy-codegen.rs, so they spell explicit snake_case CodingKeys and decode through
/// PolicyWireCoding.decoder. SignalPriority/AckResult/SessionSignalStatus are referenced bare -
/// the hand enums decode identically under any key strategy and SessionSignalStatus keeps its
/// `acknowledged` legacy alias. HarnessMonitorSignalModels+Wire.swift maps wire -> rich model.
@Suite("Session signal wire decoding")
struct SessionSignalWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  private let recordPayload = #"""
    {
      "runtime": "claude",
      "agent_id": "agent-1",
      "session_id": "sess-1",
      "status": "delivered",
      "signal": {
        "signal_id": "sig-1",
        "version": 2,
        "created_at": "2026-06-18T10:00:00Z",
        "expires_at": "2026-06-18T11:00:00Z",
        "source_agent": "leader",
        "command": "start_task",
        "priority": "high",
        "payload": {
          "message": "go",
          "action_hint": "begin",
          "related_files": ["a.rs", "b.rs"],
          "metadata": {"task": "t-1"}
        },
        "delivery": {"max_retries": 3, "retry_count": 1, "idempotency_key": "idem-1"}
      },
      "acknowledgment": {
        "signal_id": "sig-1",
        "acknowledged_at": "2026-06-18T10:05:00Z",
        "result": "accepted",
        "agent": "agent-1",
        "session_id": "sess-1",
        "details": "done"
      }
    }
    """#

  @Test("full signal record maps every field through the wire")
  func fullRecordMapsEveryField() throws {
    let data = try #require(recordPayload.data(using: .utf8))
    let wire = try decoder.decode(SessionSignalRecordWire.self, from: data)
    let record = SessionSignalRecord(wire: wire)

    #expect(record.runtime == "claude")
    #expect(record.agentId == "agent-1")
    #expect(record.sessionId == "sess-1")
    #expect(record.status == .delivered)

    #expect(record.signal.signalId == "sig-1")
    #expect(record.signal.version == 2)
    #expect(record.signal.sourceAgent == "leader")
    #expect(record.signal.priority == .high)
    #expect(record.signal.payload.message == "go")
    #expect(record.signal.payload.actionHint == "begin")
    #expect(record.signal.payload.relatedFiles == ["a.rs", "b.rs"])
    #expect(record.signal.payload.metadata == .object(["task": .string("t-1")]))
    #expect(record.signal.delivery.maxRetries == 3)
    #expect(record.signal.delivery.retryCount == 1)
    #expect(record.signal.delivery.idempotencyKey == "idem-1")

    let ack = try #require(record.acknowledgment)
    #expect(ack.result == .accepted)
    #expect(ack.agent == "agent-1")
    #expect(ack.details == "done")
    #expect(record.id == "sig-1")
  }

  @Test("the acknowledged legacy alias decodes to delivered through the bare status enum")
  func acknowledgedAliasMapsToDelivered() throws {
    let payload = #"""
      {
        "runtime": "claude",
        "agent_id": "agent-2",
        "session_id": "sess-2",
        "status": "acknowledged",
        "signal": {
          "signal_id": "sig-2",
          "version": 1,
          "created_at": "2026-06-18T10:00:00Z",
          "expires_at": "2026-06-18T11:00:00Z",
          "source_agent": "leader",
          "command": "ping",
          "priority": "normal",
          "payload": {"message": "hi"},
          "delivery": {"max_retries": 0}
        }
      }
      """#
    let data = try #require(payload.data(using: .utf8))
    let wire = try decoder.decode(SessionSignalRecordWire.self, from: data)
    let record = SessionSignalRecord(wire: wire)

    #expect(record.status == .delivered)
    // The signal payload omits metadata/action_hint/related_files and the record omits the
    // acknowledgment; the wire defaults + the metadata normalization match the hand model.
    #expect(record.signal.payload.metadata == .object([:]))
    #expect(record.signal.payload.actionHint == nil)
    #expect(record.signal.payload.relatedFiles.isEmpty)
    #expect(record.signal.delivery.retryCount == 0)
    #expect(record.acknowledgment == nil)
  }
}
