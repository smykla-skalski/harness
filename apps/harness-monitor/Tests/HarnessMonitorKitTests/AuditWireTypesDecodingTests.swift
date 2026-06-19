import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract regression for the `/v1/audit/events` request and response.
/// The audit wire types are generated from the Rust audit protocol by
/// examples/policy-codegen.rs, so they spell explicit snake_case `CodingKeys`
/// and decode through `PolicyWireCoding.decoder` (no key strategy). The rich
/// `HarnessMonitorAuditEvent` keeps a `Date` timestamp and idiomatic acronym
/// names; `HarnessMonitorAuditModels+Wire.swift` maps wire -> model at the
/// transport boundary instead of leaning on the daemon's snake keys lining up
/// with the rich model's camelCase persistence keys. This feeds the daemon's
/// byte-for-byte payload through that pairing and asserts every field survives.
@Suite("Audit wire types decoding")
struct AuditWireTypesDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  /// Byte-for-byte daemon payload: snake_case wire keys, a nested payload_json
  /// object, a related_urls list, and the next_cursor / has_older paging fields.
  private let daemonPayload = #"""
    {
      "events": [
        {
          "id": "supervisor:tick-9",
          "recorded_at": "2026-06-15T18:30:45.250Z",
          "source": "supervisor",
          "category": "decision",
          "kind": "actionDispatched",
          "severity": "info",
          "outcome": "success",
          "title": "Action Dispatched",
          "summary": "Dispatched rule r-1",
          "subject": "r-1",
          "actor": "Supervisor",
          "correlation_id": "tick-9",
          "action_key": "actionDispatched",
          "payload_json": {"rule_id": "r-1", "tick_id": "tick-9"},
          "legacy_message": null,
          "related_urls": ["https://example.com/pr/1"]
        }
      ],
      "next_cursor": "cursor-8",
      "has_older": true
    }
    """#

  @Test("decodes the daemon response and maps it to the rich model")
  func decodesResponse() throws {
    let wire = try decoder.decode(
      HarnessMonitorAuditEventsResponseWire.self,
      from: Data(daemonPayload.utf8)
    )
    let response = HarnessMonitorAuditEventsResponse(wire: wire)

    #expect(response.nextCursor == "cursor-8")
    #expect(response.hasOlder == true)

    let event = try #require(response.events.first)
    #expect(event.id == "supervisor:tick-9")
    #expect(event.source == "supervisor")
    #expect(event.kind == "actionDispatched")
    #expect(event.correlationID == "tick-9")
    #expect(event.actionKey == "actionDispatched")
    #expect(event.legacyMessage == nil)
    #expect(event.relatedURLs == ["https://example.com/pr/1"])
  }

  @Test("parses the snake_case recorded_at string into a Date")
  func parsesRecordedAt() throws {
    let wire = try decoder.decode(
      HarnessMonitorAuditEventsResponseWire.self,
      from: Data(daemonPayload.utf8)
    )
    let event = try #require(HarnessMonitorAuditEventsResponse(wire: wire).events.first)
    let expected = try #require(
      HarnessMonitorAuditEvent.parseDate("2026-06-15T18:30:45.250Z")
    )
    #expect(event.recordedAt == expected)
    #expect(event.recordedAt != .distantPast)
  }

  @Test("preserves the nested payload_json object as JSONValue")
  func preservesPayloadJSON() throws {
    let wire = try decoder.decode(
      HarnessMonitorAuditEventsResponseWire.self,
      from: Data(daemonPayload.utf8)
    )
    let event = try #require(HarnessMonitorAuditEventsResponse(wire: wire).events.first)
    guard case .object(let payload)? = event.payloadJSON else {
      Issue.record("expected payload_json to map to a JSONValue object")
      return
    }
    #expect(payload["rule_id"] == .string("r-1"))
    #expect(payload["tick_id"] == .string("tick-9"))
  }

  @Test("degrades a malformed timestamp to distantPast without failing the page")
  func degradesMalformedTimestamp() throws {
    let json = #"""
      {"events":[{"id":"x","recorded_at":"not-a-date","source":"s","category":"c",
      "kind":"k","severity":"info","outcome":"success","title":"t","summary":"y",
      "related_urls":[]}],"has_older":false}
      """#
    let wire = try decoder.decode(
      HarnessMonitorAuditEventsResponseWire.self,
      from: Data(json.utf8)
    )
    let response = HarnessMonitorAuditEventsResponse(wire: wire)
    #expect(response.events.first?.recordedAt == .distantPast)
  }

  @Test("maps a rich request to the wire type with snake_case keys")
  func mapsRequestToWire() throws {
    let request = HarnessMonitorAuditEventsRequest(
      limit: 25,
      before: "cursor-1",
      dateRange: HarnessMonitorAuditDateRange(start: "2026-06-01", end: "2026-06-15"),
      sources: ["supervisor"],
      actionKeys: ["actionDispatched"],
      searchText: "rule"
    )
    let wire = HarnessMonitorAuditEventsRequestWire(request)
    #expect(wire.limit == 25)
    #expect(wire.dateRange?.start == "2026-06-01")
    #expect(wire.dateRange?.end == "2026-06-15")

    // A plain encoder (no key strategy) must already emit snake_case keys,
    // proving the wire type's explicit CodingKeys are authoritative.
    let object = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as? [String: Any]
    )
    #expect(object["date_range"] != nil)
    #expect(object["action_keys"] as? [String] == ["actionDispatched"])
    #expect(object["search_text"] as? String == "rule")
    #expect(object["limit"] as? Int == 25)
  }
}
