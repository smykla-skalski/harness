import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract and mapping for the acp inspect response, generated from the owned
/// AcpAgentInspectSnapshotDecode (the rich snapshot carries no serde derive). The wire keeps
/// the daemon field names and drops managed_agent_family; the map applies the hand cross-rename
/// (managed_agent_id -> acpId, session_agent_id -> agentId) and narrows UInt counts to Int. The
/// /v1/managed-agents/acp/inspect endpoint is rerouted onto it.
@Suite("Acp inspect wire type")
struct AcpInspectWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes the inspect response, ignoring the dropped family field")
  func decodesInspect() throws {
    let wire = try decoder.decode(
      AcpAgentInspectResponseWire.self, from: Data(inspectFixture.utf8)
    )
    #expect(wire.available)
    #expect(wire.daemonPerceivedNow == "2026-06-18T00:00:01Z")
    let agent = try #require(wire.agents.first)
    #expect(agent.managedAgentId == "acp-1")
    #expect(agent.sessionAgentId == "worker-2")
    #expect(agent.processKey == "proc-1")
    #expect(agent.terminalCount == 1)
  }

  @Test("maps the inspect response with the cross-renamed identifiers")
  func mapsInspect() throws {
    let wire = try decoder.decode(
      AcpAgentInspectResponseWire.self, from: Data(inspectFixture.utf8)
    )
    let response = AcpAgentInspectResponse(wire: wire)
    #expect(response.available)
    let agent = try #require(response.agents.first)
    #expect(agent.id == "acp-1")
    #expect(agent.acpId == "acp-1")
    #expect(agent.agentId == "worker-2")
    #expect(agent.displayName == "Copilot")
    #expect(agent.terminalCount == 1)
    #expect(agent.promptDeadlineRemainingMs == 60000)
  }
}

private let inspectFixture = """
  {
    "agents": [
      {
        "managed_agent_id": "acp-1",
        "managed_agent_family": "acp",
        "session_id": "sess-1",
        "session_agent_id": "worker-2",
        "display_name": "Copilot",
        "pid": 42,
        "pgid": 42,
        "process_key": "proc-1",
        "uptime_ms": 1000,
        "last_update_at": "2026-06-18T00:00:00Z",
        "last_client_call_at": null,
        "watchdog_state": "healthy",
        "permission_mode": "ask",
        "permission_log_path": null,
        "pending_permissions": 0,
        "permission_queue_depth": 0,
        "terminal_count": 1,
        "prompt_deadline_remaining_ms": 60000
      }
    ],
    "daemon_perceived_now": "2026-06-18T00:00:01Z",
    "available": true,
    "issue_message": null
  }
  """
