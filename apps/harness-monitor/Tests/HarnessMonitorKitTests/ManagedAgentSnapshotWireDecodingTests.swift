import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract and mapping for the managed-agent snapshot umbrella, generated from
/// protocol/managed_agents.rs. ManagedAgentSnapshot is adjacently tagged (kind + snapshot) over
/// the three transport snapshots; the acp arm is the one this work unblocked (it re-decodes the
/// generated AcpAgentSnapshotWire). The list response wraps it. These are the managed-agent
/// endpoint return types, rerouted on both transports.
@Suite("Managed agent snapshot wire type")
struct ManagedAgentSnapshotWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes and maps an acp variant through the adjacently-tagged umbrella")
  func mapsAcpVariant() throws {
    let wire = try decoder.decode(ManagedAgentSnapshotWire.self, from: Data(acpSnapshotFixture.utf8))
    guard case .acp(let acpWire) = wire else {
      Issue.record("expected an acp variant")
      return
    }
    #expect(acpWire.managedAgentId == "acp-1")

    let snapshot = try ManagedAgentSnapshot(wire: wire)
    guard case .acp(let acp) = snapshot else {
      Issue.record("expected the mapped acp variant")
      return
    }
    #expect(acp.acpId == "acp-1")
    #expect(acp.agentId == "worker-2")
    #expect(snapshot.family == .acp)
    #expect(snapshot.agentId == "acp-1")
  }

  @Test("maps the list response wrapping the umbrella")
  func mapsListResponse() throws {
    let wire = try decoder.decode(
      ManagedAgentListResponseWire.self, from: Data(listFixture.utf8)
    )
    let response = try ManagedAgentListResponse(wire: wire)
    #expect(response.agents.count == 1)
    #expect(response.agents.first?.agentId == "acp-1")
  }
}

private let acpSnapshotFixture = """
  {
    "kind": "acp",
    "snapshot": {
      "managed_agent_id": "acp-1",
      "managed_agent_family": "acp",
      "session_id": "sess-1",
      "session_agent_id": "worker-2",
      "display_name": "Copilot",
      "status": "active",
      "pid": 42,
      "pgid": 42,
      "project_dir": "/tmp/project",
      "process_key": "pk",
      "pending_permissions": 0,
      "permission_queue_depth": 0,
      "pending_permission_batches": [],
      "permission_mode": "",
      "permission_log_path": null,
      "terminal_count": 1,
      "created_at": "2026-06-18T00:00:00Z",
      "updated_at": "2026-06-18T00:00:01Z"
    }
  }
  """

private let listFixture = """
  {
    "agents": [
      \(acpSnapshotFixture)
    ]
  }
  """
