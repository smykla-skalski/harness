import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract and mapping for the codex inspect/transcript responses (generated into
/// CodexWireTypes). Both decode through the plain decoder and map to the hand models - the
/// inspect snapshot narrows UInt counts to Int, the transcript reuses the TimelineEntry wire.
/// The /v1/managed-agents/codex inspect and transcript endpoints are rerouted onto them.
@Suite("Codex inspect/transcript wire type")
struct CodexInspectWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes and maps a codex inspect response")
  func decodesInspect() throws {
    let wire = try decoder.decode(
      CodexAgentInspectResponseWire.self, from: Data(inspectFixture.utf8)
    )
    #expect(wire.available)
    #expect(wire.daemonPerceivedNow == "2026-06-18T00:00:01Z")
    let agent = try #require(wire.agents.first)
    #expect(agent.runId == "run-1")
    #expect(agent.eventCount == 5)

    let response = CodexAgentInspectResponse(wire: wire)
    let mapped = try #require(response.agents.first)
    #expect(mapped.id == "run-1")
    #expect(mapped.eventCount == 5)
    #expect(mapped.resolvedApprovals == 1)
    #expect(mapped.model == "gpt-5")
  }

  @Test("decodes and maps a codex transcript response")
  func decodesTranscript() throws {
    let wire = try decoder.decode(
      CodexTranscriptResponseWire.self, from: Data(transcriptFixture.utf8)
    )
    #expect(wire.entries.count == 1)

    let response = CodexTranscriptResponse(wire: wire)
    let entry = try #require(response.entries.first)
    #expect(entry.entryId == "e1")
    #expect(entry.summary == "did a thing")
    #expect(entry.agentId == "worker")
  }
}

private let inspectFixture = """
  {
    "agents": [
      {
        "run_id": "run-1",
        "session_id": "sess-1",
        "agent_id": "worker",
        "display_name": "Codex",
        "status": "running",
        "project_dir": "/tmp/project",
        "thread_id": null,
        "turn_id": null,
        "active": true,
        "attached": false,
        "pending_approvals": 0,
        "resolved_approvals": 1,
        "event_count": 5,
        "last_update_at": "2026-06-18T00:00:00Z",
        "model": "gpt-5",
        "effort": "high",
        "latest_summary": "working",
        "error": null
      }
    ],
    "daemon_perceived_now": "2026-06-18T00:00:01Z",
    "available": true,
    "issue_message": null
  }
  """

private let transcriptFixture = """
  {
    "entries": [
      {
        "entry_id": "e1",
        "recorded_at": "2026-06-18T00:00:00Z",
        "kind": "message",
        "session_id": "sess-1",
        "agent_id": "worker",
        "task_id": null,
        "summary": "did a thing",
        "payload": {}
      }
    ]
  }
  """
