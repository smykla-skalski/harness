import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract for StreamEvent, generated from src/daemon/protocol/summaries.rs.
/// StreamEvent is the server-sent-event envelope whose payload is a free-form
/// serde_json::Value, generated as JSONValue. This proves the daemon's snake_case
/// SSE frame decodes into the typed wire form through the plain decoder, payload
/// intact. generate-only - the rich hand StreamEvent (Identifiable) stays until the
/// stream reroute.
@Suite("Stream event wire type")
struct StreamEventWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes a stream event with its free-form payload")
  func decodesStreamEvent() throws {
    let event = try decoder.decode(
      StreamEventWire.self, from: Data(streamEventPayloadFixture.utf8)
    )

    #expect(event.event == "task_update")
    #expect(event.recordedAt == "2026-06-17T10:00:00Z")
    #expect(event.sessionId == "sig-1")

    let payload = try #require(objectValue(event.payload))
    #expect(payload["status"] == .string("in_review"))
  }

  @Test("decodes a stream event with no session id")
  func decodesWithoutSessionId() throws {
    let event = try decoder.decode(
      StreamEventWire.self,
      from: Data(#"{"event": "ping", "recorded_at": "2026-06-17T10:00:00Z", "payload": null}"#.utf8)
    )
    #expect(event.event == "ping")
    #expect(event.sessionId == nil)
    #expect(event.payload == .null)
  }

  private func objectValue(_ value: JSONValue) -> [String: JSONValue]? {
    if case .object(let dict) = value { return dict }
    return nil
  }
}

private let streamEventPayloadFixture = """
  {
    "event": "task_update",
    "recorded_at": "2026-06-17T10:00:00Z",
    "session_id": "sig-1",
    "payload": { "status": "in_review" }
  }
  """
