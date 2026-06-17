import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract for the timeline responses that nest TimelineEntry, generated from
/// src/daemon/protocol/summaries.rs. TimelineWindowResponse carries the paged entries
/// plus before/after cursors and the unchanged-poll flag; AcpTranscriptResponse is the
/// flat entry list. Both unblocked once TimelineEntry generated. These prove the
/// nested entry/cursor graph decodes through the plain decoder. generate-only.
@Suite("Timeline response wire types")
struct TimelineResponseWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes a window response with entries and cursors")
  func decodesWindowResponse() throws {
    let response = try decoder.decode(
      TimelineWindowResponseWire.self, from: Data(windowResponsePayloadFixture.utf8)
    )

    #expect(response.revision == 12)
    #expect(response.totalCount == 100)
    #expect(response.hasNewer == true)
    #expect(response.unchanged == false)

    let oldest = try #require(response.oldestCursor)
    #expect(oldest.entryId == "e-1")

    let entries = try #require(response.entries)
    #expect(entries.count == 1)
    #expect(entries[0].entryId == "e-20")
  }

  @Test("decodes an unchanged window response with null entries")
  func decodesUnchangedWindowResponse() throws {
    let response = try decoder.decode(
      TimelineWindowResponseWire.self, from: Data(unchangedWindowFixture.utf8)
    )
    #expect(response.unchanged == true)
    #expect(response.entries == nil)
    #expect(response.oldestCursor == nil)
  }

  @Test("decodes an acp transcript response")
  func decodesAcpTranscript() throws {
    let response = try decoder.decode(
      AcpTranscriptResponseWire.self, from: Data(acpTranscriptPayloadFixture.utf8)
    )
    #expect(response.entries.count == 2)
    #expect(response.entries[0].kind == "prompt")
    #expect(response.entries[1].entryId == "e-2")
  }
}

private let windowResponsePayloadFixture = """
  {
    "revision": 12,
    "total_count": 100,
    "window_start": 0,
    "window_end": 20,
    "has_older": false,
    "has_newer": true,
    "oldest_cursor": { "recorded_at": "2026-06-17T10:00:00Z", "entry_id": "e-1" },
    "newest_cursor": { "recorded_at": "2026-06-17T10:20:00Z", "entry_id": "e-20" },
    "entries": [
      {
        "entry_id": "e-20",
        "recorded_at": "2026-06-17T10:20:00Z",
        "kind": "note",
        "session_id": "sig-1",
        "summary": "Latest",
        "payload": null
      }
    ],
    "unchanged": false
  }
  """

private let unchangedWindowFixture = """
  {
    "revision": 12,
    "total_count": 100,
    "window_start": 0,
    "window_end": 20,
    "has_older": false,
    "has_newer": false,
    "oldest_cursor": null,
    "newest_cursor": null,
    "entries": null,
    "unchanged": true
  }
  """

private let acpTranscriptPayloadFixture = """
  {
    "entries": [
      {
        "entry_id": "e-1",
        "recorded_at": "2026-06-17T09:00:00Z",
        "kind": "prompt",
        "session_id": "sig-1",
        "summary": "Prompt sent",
        "payload": { "text": "hello" }
      },
      {
        "entry_id": "e-2",
        "recorded_at": "2026-06-17T09:01:00Z",
        "kind": "response",
        "session_id": "sig-1",
        "summary": "Response received",
        "payload": null
      }
    ]
  }
  """
