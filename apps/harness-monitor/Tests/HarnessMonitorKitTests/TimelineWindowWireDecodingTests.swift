import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract for the timeline pagination cursor and window request, generated
/// from src/daemon/protocol/summaries.rs. TimelineWindowRequest nests TimelineCursor
/// (before/after). Both decode through the plain decoder, proving the daemon's
/// snake_case shape lands in the typed wire form including the serde(default) optional
/// pagination params. generate-only - the rich hand TimelineCursor/TimelineWindowRequest
/// stay until the timeline reroute (the window response defers, it nests the codex
/// -referenced TimelineEntry).
@Suite("Timeline window wire types")
struct TimelineWindowWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes a window request with a nested before cursor")
  func decodesWindowRequestWithCursor() throws {
    let request = try decoder.decode(
      TimelineWindowRequestWire.self, from: Data(windowRequestPayloadFixture.utf8)
    )

    #expect(request.scope == "session")
    #expect(request.limit == 50)
    #expect(request.knownRevision == 7)

    let before = try #require(request.before)
    #expect(before.entryId == "e-100")
    #expect(before.recordedAt == "2026-06-17T10:00:00Z")
    #expect(request.after == nil)
  }

  @Test("defaults an empty window request to all-nil pagination")
  func decodesEmptyWindowRequest() throws {
    let request = try decoder.decode(TimelineWindowRequestWire.self, from: Data("{}".utf8))
    #expect(request.scope == nil)
    #expect(request.limit == nil)
    #expect(request.before == nil)
    #expect(request.knownRevision == nil)
  }

  @Test("decodes a standalone TimelineCursorWire")
  func decodesTimelineCursor() throws {
    let cursor = try decoder.decode(
      TimelineCursorWire.self,
      from: Data(#"{"recorded_at": "2026-06-17T09:00:00Z", "entry_id": "e-1"}"#.utf8)
    )
    #expect(cursor.recordedAt == "2026-06-17T09:00:00Z")
    #expect(cursor.entryId == "e-1")
  }
}

private let windowRequestPayloadFixture = """
  {
    "scope": "session",
    "limit": 50,
    "before": { "recorded_at": "2026-06-17T10:00:00Z", "entry_id": "e-100" },
    "known_revision": 7
  }
  """
