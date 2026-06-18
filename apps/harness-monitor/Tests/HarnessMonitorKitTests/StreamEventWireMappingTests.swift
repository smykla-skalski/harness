import Foundation
import Testing

@testable import HarnessMonitorKit

/// Map-contract regression for the SSE push envelope (StreamEvent) now decoded through
/// StreamEventWire on the stream-parse path. Thin mirror; the payload is a free-form JSONValue.
@Suite("Stream event wire mapping")
struct StreamEventWireMappingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("stream event decodes its snake keys and free-form payload through the wire")
  func streamEventMapping() throws {
    let data = try #require(
      #"""
      {"event": "task.updated", "recorded_at": "2026-06-18T10:00:00Z",
       "session_id": "s1", "payload": {"task_id": "t1"}}
      """#.data(using: .utf8)
    )
    let wire = try decoder.decode(StreamEventWire.self, from: data)
    let event = StreamEvent(wire: wire)
    #expect(event.event == "task.updated")
    #expect(event.recordedAt == "2026-06-18T10:00:00Z")
    #expect(event.sessionId == "s1")
    #expect(event.payload == .object(["task_id": .string("t1")]))
  }
}
