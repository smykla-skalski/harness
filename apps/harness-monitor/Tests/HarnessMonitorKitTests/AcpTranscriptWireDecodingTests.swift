import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract and mapping for the acp transcript response (entries: [TimelineEntry],
/// generated into SummariesWireTypes). It decodes through the plain decoder and reuses the
/// TimelineEntry wire map. The /v1/managed-agents/acp/transcript endpoint is rerouted onto it.
@Suite("Acp transcript wire type")
struct AcpTranscriptWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes and maps an acp transcript response")
  func decodesTranscript() throws {
    let wire = try decoder.decode(
      AcpTranscriptResponseWire.self, from: Data(transcriptFixture.utf8)
    )
    #expect(wire.entries.count == 1)

    let response = AcpTranscriptResponse(wire: wire)
    let entry = try #require(response.entries.first)
    #expect(entry.entryId == "e1")
    #expect(entry.kind == "permission")
    #expect(entry.summary == "approved fs_write")
  }
}

private let transcriptFixture = """
  {
    "entries": [
      {
        "entry_id": "e1",
        "recorded_at": "2026-06-18T00:00:00Z",
        "kind": "permission",
        "session_id": "sess-1",
        "agent_id": "copilot",
        "task_id": null,
        "summary": "approved fs_write",
        "payload": {}
      }
    ]
  }
  """
