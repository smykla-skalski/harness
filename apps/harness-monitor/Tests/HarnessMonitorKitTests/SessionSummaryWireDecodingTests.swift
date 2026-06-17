import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract for SessionSummary, generated from src/daemon/protocol/summaries.rs.
/// SessionSummary is the dashboard's core session type and the biggest SessionDetail
/// member. SessionSummaryWire ties together the session-state leaf: status decodes as
/// the adopted SessionStatus enum, pendingLeaderTransfer as PendingLeaderTransferWire,
/// and metrics as SessionMetricsWire - proving the daemon's nested snake_case payload
/// lands in the typed wire graph through the plain decoder. The rich hand SessionSummary
/// keeps its Int metrics and decodes via convertFromSnakeCase until the SessionDetail
/// reroute adopts this.
@Suite("Session summary wire graph")
struct SessionSummaryWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes the full session summary graph with nested deps")
  func decodesSessionSummaryGraph() throws {
    let summary = try decoder.decode(
      SessionSummaryWire.self, from: Data(sessionSummaryPayloadFixture.utf8)
    )

    #expect(summary.sessionId == "sig-1")
    #expect(summary.projectDir == "code/harness")
    #expect(summary.status == .active)
    #expect(summary.observeId == nil)
    #expect(summary.externalOrigin == nil)

    let transfer = try #require(summary.pendingLeaderTransfer)
    #expect(transfer.requestedBy == "worker-3")
    #expect(transfer.newLeaderId == "worker-3")
    #expect(transfer.reason == "leader idle")

    #expect(summary.metrics.agentCount == 5)
    #expect(summary.metrics.completedTaskCount == 12)
    #expect(summary.metrics.arbitrationTaskCount == 0)
  }

  @Test("decodes a summary whose pending leader transfer is null")
  func decodesWithoutPendingLeaderTransfer() throws {
    let summary = try decoder.decode(
      SessionSummaryWire.self, from: Data(sessionSummaryNoTransferFixture.utf8)
    )
    #expect(summary.status == .leaderlessDegraded)
    #expect(summary.pendingLeaderTransfer == nil)
    #expect(summary.metrics.agentCount == 0)
  }

  @Test("decodes PendingLeaderTransferWire from the daemon snake keys")
  func decodesPendingLeaderTransfer() throws {
    let transfer = try decoder.decode(
      PendingLeaderTransferWire.self, from: Data(pendingTransferPayloadFixture.utf8)
    )
    #expect(transfer.requestedBy == "worker-3")
    #expect(transfer.currentLeaderId == "claude-leader")
    #expect(transfer.newLeaderId == "worker-3")
    #expect(transfer.reason == nil)
  }
}

private let sessionSummaryPayloadFixture = """
  {
    "project_id": "proj-1",
    "project_name": "harness",
    "project_dir": "code/harness",
    "context_root": "sessions/harness",
    "worktree_path": "sessions/harness/sig-1/workspace",
    "shared_path": "sessions/harness/sig-1/memory",
    "origin_path": "code/harness",
    "branch_ref": "harness/sig-1",
    "session_id": "sig-1",
    "title": "Wire migration",
    "context": "Generate session summary wire types",
    "status": "active",
    "created_at": "2026-06-17T10:00:00Z",
    "updated_at": "2026-06-17T10:05:00Z",
    "last_activity_at": "2026-06-17T10:04:30Z",
    "leader_id": "claude-leader",
    "observe_id": null,
    "pending_leader_transfer": {
      "requested_by": "worker-3",
      "current_leader_id": "claude-leader",
      "new_leader_id": "worker-3",
      "requested_at": "2026-06-17T10:03:00Z",
      "reason": "leader idle"
    },
    "metrics": {
      "agent_count": 5,
      "active_agent_count": 3,
      "open_task_count": 8,
      "completed_task_count": 12
    }
  }
  """

private let sessionSummaryNoTransferFixture = """
  {
    "project_id": "proj-1",
    "project_name": "harness",
    "context_root": "sessions/harness",
    "worktree_path": "sessions/harness/sig-1/workspace",
    "shared_path": "sessions/harness/sig-1/memory",
    "origin_path": "code/harness",
    "branch_ref": "harness/sig-1",
    "session_id": "sig-1",
    "title": "Wire migration",
    "context": "Degraded session",
    "status": "leaderless_degraded",
    "created_at": "2026-06-17T10:00:00Z",
    "updated_at": "2026-06-17T10:05:00Z",
    "pending_leader_transfer": null,
    "metrics": {}
  }
  """

private let pendingTransferPayloadFixture = """
  {
    "requested_by": "worker-3",
    "current_leader_id": "claude-leader",
    "new_leader_id": "worker-3",
    "requested_at": "2026-06-17T10:03:00Z"
  }
  """
