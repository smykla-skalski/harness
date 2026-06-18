import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract and mapping for the full acp managed-agent snapshot (the Acp variant of
/// ManagedAgentSnapshot), generated from its owned AcpAgentSnapshotDecode. status is a JSONValue
/// passthrough; the map re-decodes the flattened AgentStatus and, when disconnected, the
/// reason/stderr_tail the daemon nests in the status object. managed_agent_id/session_agent_id
/// cross-rename to acpId/agentId and the permission batches reuse the permission wire.
@Suite("Acp agent snapshot wire type")
struct AcpAgentSnapshotWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("maps an active snapshot with permission batches and the cross-renamed ids")
  func mapsActiveSnapshot() throws {
    let wire = try decoder.decode(AcpAgentSnapshotWire.self, from: Data(activeFixture.utf8))
    let snapshot = try AcpAgentSnapshot(wire: wire)
    #expect(snapshot.id == "worker-2")
    #expect(snapshot.acpId == "acp-1")
    #expect(snapshot.agentId == "worker-2")
    #expect(snapshot.status == .active)
    #expect(snapshot.disconnectReason == nil)
    #expect(snapshot.pendingPermissions == 1)
    #expect(snapshot.terminalCount == 2)
    let batch = try #require(snapshot.pendingPermissionBatches.first)
    #expect(batch.acpId == "acp-1")
    #expect(batch.requests.first?.requestId == "req-1")
  }

  @Test("recovers the disconnect reason and stderr tail from the status object")
  func mapsDisconnectedSnapshot() throws {
    let wire = try decoder.decode(AcpAgentSnapshotWire.self, from: Data(disconnectedFixture.utf8))
    let snapshot = try AcpAgentSnapshot(wire: wire)
    #expect(snapshot.status == .disconnected)
    #expect(snapshot.disconnectReason?.kind == "process_exited")
    #expect(snapshot.disconnectReason?.code == 1)
    #expect(snapshot.stderrTail == "boom")
    #expect(snapshot.isRestartable)
  }
}

private let activeFixture = """
  {
    "managed_agent_id": "acp-1",
    "managed_agent_family": "acp",
    "session_id": "sess-1",
    "session_agent_id": "worker-2",
    "display_name": "Copilot",
    "status": "active",
    "pid": 42,
    "pgid": 42,
    "project_dir": "/tmp/project",
    "process_key": "proc-1",
    "pending_permissions": 1,
    "permission_queue_depth": 0,
    "pending_permission_batches": [
      {
        "batch_id": "batch-1",
        "managed_agent_id": "acp-1",
        "managed_agent_family": "acp",
        "session_id": "sess-1",
        "requests": [
          {
            "request_id": "req-1",
            "session_id": "sess-1",
            "tool_call": { "name": "fs_write" },
            "options": []
          }
        ],
        "created_at": "2026-06-18T00:00:00Z",
        "expires_at": "2026-06-18T00:05:00Z"
      }
    ],
    "permission_mode": "ask",
    "permission_log_path": null,
    "terminal_count": 2,
    "created_at": "2026-06-18T00:00:00Z",
    "updated_at": "2026-06-18T00:00:01Z"
  }
  """

private let disconnectedFixture = """
  {
    "managed_agent_id": "acp-1",
    "managed_agent_family": "acp",
    "session_id": "sess-1",
    "session_agent_id": "worker-2",
    "display_name": "Copilot",
    "status": { "state": "disconnected", "reason": { "kind": "process_exited", "code": 1 }, "stderr_tail": "boom" },
    "pid": 42,
    "pgid": 42,
    "project_dir": "/tmp/project",
    "process_key": "proc-1",
    "pending_permissions": 0,
    "permission_queue_depth": 0,
    "pending_permission_batches": [],
    "permission_mode": "",
    "permission_log_path": null,
    "terminal_count": 0,
    "created_at": "2026-06-18T00:00:00Z",
    "updated_at": "2026-06-18T00:00:01Z"
  }
  """
