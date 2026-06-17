import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract for TimelineEntry, generated from src/daemon/protocol/summaries.rs.
/// TimelineEntry is the high-traffic timeline row whose payload is a free-form
/// serde_json::Value, generated as JSONValue. It was referenced bare by the codex
/// wire types, so suffixing it to TimelineEntryWire repointed that ref and the codex
/// mapping now bridges each entry through TimelineEntry(wire:). These prove the
/// arbitrary payload survives the plain decoder and the pass-through map.
@Suite("Timeline entry wire type")
struct TimelineEntryWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes a timeline entry including its free-form payload")
  func decodesTimelineEntryWithPayload() throws {
    let entry = try decoder.decode(
      TimelineEntryWire.self, from: Data(timelineEntryPayloadFixture.utf8)
    )

    #expect(entry.entryId == "e-1")
    #expect(entry.kind == "task_update")
    #expect(entry.sessionId == "sig-1")
    #expect(entry.agentId == "agent-9")
    #expect(entry.taskId == "t-1")

    let payload = try #require(objectValue(entry.payload))
    #expect(payload["to"] == .string("in_review"))
    #expect(payload["count"] == .number(3))
  }

  @Test("decodes an entry with absent optional ids")
  func decodesEntryWithoutOptionalIds() throws {
    let entry = try decoder.decode(
      TimelineEntryWire.self, from: Data(bareTimelineEntryFixture.utf8)
    )
    #expect(entry.agentId == nil)
    #expect(entry.taskId == nil)
    #expect(entry.payload == .null)
  }

  @Test("maps the wire entry to the hand TimelineEntry")
  func mapsToHandTimelineEntry() throws {
    let wire = try decoder.decode(
      TimelineEntryWire.self, from: Data(timelineEntryPayloadFixture.utf8)
    )
    let entry = TimelineEntry(wire: wire)

    #expect(entry.id == "e-1")
    #expect(entry.summary == "Task moved to review")
    #expect(entry.payload == wire.payload)
  }

  private func objectValue(_ value: JSONValue) -> [String: JSONValue]? {
    if case .object(let dict) = value { return dict }
    return nil
  }
}

private let timelineEntryPayloadFixture = """
  {
    "entry_id": "e-1",
    "recorded_at": "2026-06-17T10:00:00Z",
    "kind": "task_update",
    "session_id": "sig-1",
    "agent_id": "agent-9",
    "task_id": "t-1",
    "summary": "Task moved to review",
    "payload": { "from": "in_progress", "to": "in_review", "count": 3 }
  }
  """

private let bareTimelineEntryFixture = """
  {
    "entry_id": "e-2",
    "recorded_at": "2026-06-17T10:01:00Z",
    "kind": "note",
    "session_id": "sig-1",
    "summary": "A note",
    "payload": null
  }
  """
